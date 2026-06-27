defmodule GcIndexRelayWeb.AuthController do
  @moduledoc """
  Authentication endpoints for the Mycelium admin system.

  ## Endpoints

  - `POST /api/auth/claim-admin` — First-claim admin bootstrap (Lemmy-style).
    Only works when no admin exists. Accepts a signed Nostr event (kind 27235)
    and registers the signer as the site admin.

  - `POST /api/auth/token` — Issue a Phoenix.Token for an authenticated pubkey.
    Accepts a signed Nostr event (kind 27235) and returns a bearer token
    valid for 1 hour. The token encodes the pubkey; role is resolved per-request.
  """

  use GcIndexRelayWeb, :controller

  alias GcIndexRelay.Auth.Roles
  alias GcIndexRelay.Nostr.Validator

  @token_salt "mercury_auth"
  @max_event_age_sec 120  # signed event must be within ±2 minutes

  @doc """
  First-claim admin bootstrap.

  Accepts:
  ```json
  {
    "event": {
      "id": "...",
      "pubkey": "...",
      "created_at": <unix_sec>,
      "kind": 27235,
      "tags": [["u", "<this-endpoint-url>"], ["method", "POST"]],
      "content": "",
      "sig": "..."
    }
  }
  ```

  Returns 201 with a token on success, or 403 if admin already claimed.
  """
  def claim_admin(conn, %{"event" => event_params}) do
    with {:unclaimed, true} <- {:unclaimed, Roles.admin_unclaimed?()},
         {:ok, event} <- parse_and_verify_auth_event(event_params),
         {:ok, admin} <- Roles.claim_admin(event.pubkey, "first-claim") do
      token = Phoenix.Token.sign(GcIndexRelayWeb.Endpoint, @token_salt, admin.pubkey)

      conn
      |> put_status(:created)
      |> json(%{
        ok: true,
        message: "Admin claimed successfully",
        pubkey: admin.pubkey,
        token: token,
        role: "admin",
        expires_in: 3600
      })
    else
      {:unclaimed, false} ->
        conn |> put_status(:forbidden) |> json(%{error: "Admin already claimed"})

      {:error, reason} when is_binary(reason) ->
        conn |> put_status(:bad_request) |> json(%{error: reason})

      {:error, %Ecto.Changeset{} = cs} ->
        errors = Ecto.Changeset.traverse_errors(cs, fn {msg, _opts} -> msg end)
        conn |> put_status(:unprocessable_entity) |> json(%{error: "Validation failed", details: errors})
    end
  end

  def claim_admin(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{error: "Missing 'event' parameter"})
  end

  @doc """
  Issue a bearer token for a verified Nostr pubkey.

  Accepts the same event format as claim_admin. The pubkey must already
  be a site admin to receive an admin-scoped token. Non-admin pubkeys
  receive a user-scoped token.
  """
  def create_token(conn, %{"event" => event_params}) do
    with {:ok, event} <- parse_and_verify_auth_event(event_params) do
      role = if Roles.is_admin?(event.pubkey), do: "admin", else: "user"
      token = Phoenix.Token.sign(GcIndexRelayWeb.Endpoint, @token_salt, event.pubkey)

      conn
      |> put_status(:ok)
      |> json(%{
        ok: true,
        pubkey: event.pubkey,
        token: token,
        role: role,
        expires_in: 3600
      })
    else
      {:error, reason} when is_binary(reason) ->
        conn |> put_status(:bad_request) |> json(%{error: reason})
    end
  end

  def create_token(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{error: "Missing 'event' parameter"})
  end

  # ── Private: parse and verify a NIP-42-style auth event ──

  defp parse_and_verify_auth_event(params) when is_map(params) do
    with {:ok, event} <- build_pub_event(params),
         {:ok, _} <- validate_kind(event),
         {:ok, _} <- validate_timestamp(event),
         {:ok, event} <- Validator.validate_id(event),
         {:ok, event} <- Validator.validate_signature(event) do
      {:ok, event}
    end
  end

  defp build_pub_event(params) do
    try do
      event = %GcIndexRelay.Nostr.PubEvent{
        id: Map.fetch!(params, "id"),
        pubkey: Map.fetch!(params, "pubkey"),
        created_at: Map.fetch!(params, "created_at"),
        kind: Map.fetch!(params, "kind"),
        tags: Map.get(params, "tags", []),
        content: Map.get(params, "content", ""),
        sig: Map.fetch!(params, "sig")
      }
      {:ok, event}
    rescue
      KeyError -> {:error, "Missing required event fields (id, pubkey, created_at, kind, sig)"}
    end
  end

  defp validate_kind(%{kind: 27235} = _event), do: {:ok, :valid}
  defp validate_kind(_event), do: {:error, "Event kind must be 27235 (NIP-42 AUTH)"}

  defp validate_timestamp(%{created_at: created_at}) when is_integer(created_at) do
    now = System.system_time(:second)
    diff = abs(now - created_at)

    if diff <= @max_event_age_sec do
      {:ok, :valid}
    else
      {:error, "Event timestamp is too far from current time (#{diff}s drift, max #{@max_event_age_sec}s)"}
    end
  end

  defp validate_timestamp(_), do: {:error, "created_at must be a unix timestamp integer"}
end
