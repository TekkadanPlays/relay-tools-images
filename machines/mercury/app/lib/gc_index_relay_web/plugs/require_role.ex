defmodule GcIndexRelayWeb.Plugs.RequireRole do
  @moduledoc """
  Plug that enforces role-based access control.

  Supports two authentication methods:
  1. **API Key** — `Authorization: Bearer sk_...` checked against `MERCURY_ADMIN_API_KEY` env var.
     Grants admin role automatically. Used for server-to-server, scripts, cron.
  2. **Phoenix.Token** — `Authorization: Bearer <token>` issued by AuthController.
     Contains the pubkey; role is resolved via `Roles.is_admin?/1`.

  ## Usage in router

      plug RequireRole, :admin       # only site admins
      plug RequireRole, :authenticated  # any valid token/key

  """

  import Plug.Conn
  alias GcIndexRelay.Auth.Roles

  @behaviour Plug

  @max_token_age_sec 3600  # 1 hour

  @impl true
  def init(role), do: role

  @impl true
  def call(conn, required_role) do
    case extract_bearer(conn) do
      nil ->
        unauthorized(conn, "Missing Authorization header")

      token ->
        cond do
          api_key_valid?(token) ->
            # API key grants admin. Attach synthetic pubkey "api_key".
            conn
            |> assign(:current_pubkey, "api_key")
            |> assign(:current_role, :admin)

          true ->
            verify_phoenix_token(conn, token, required_role)
        end
    end
  end

  defp extract_bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> String.trim(token)
      _ -> nil
    end
  end

  defp api_key_valid?(token) do
    case System.get_env("MERCURY_ADMIN_API_KEY") do
      nil -> false
      "" -> false
      key -> Plug.Crypto.secure_compare(key, token)
    end
  end

  defp verify_phoenix_token(conn, token, required_role) do
    endpoint = GcIndexRelayWeb.Endpoint
    salt = "mercury_auth"

    case Phoenix.Token.verify(endpoint, salt, token, max_age: @max_token_age_sec) do
      {:ok, pubkey} when is_binary(pubkey) ->
        role = resolve_role(pubkey)

        if role_sufficient?(role, required_role) do
          conn
          |> assign(:current_pubkey, pubkey)
          |> assign(:current_role, role)
        else
          forbidden(conn, "Insufficient permissions: requires #{required_role}")
        end

      {:error, :expired} ->
        unauthorized(conn, "Token expired")

      {:error, _reason} ->
        unauthorized(conn, "Invalid token")
    end
  end

  defp resolve_role(pubkey) do
    cond do
      Roles.is_admin?(pubkey) -> :admin
      true -> :user
    end
  end

  defp role_sufficient?(_has, :authenticated), do: true
  defp role_sufficient?(:admin, :admin), do: true
  defp role_sufficient?(_, :admin), do: false
  defp role_sufficient?(_, _), do: false

  defp unauthorized(conn, message) do
    conn
    |> put_status(:unauthorized)
    |> Phoenix.Controller.json(%{error: message})
    |> halt()
  end

  defp forbidden(conn, message) do
    conn
    |> put_status(:forbidden)
    |> Phoenix.Controller.json(%{error: message})
    |> halt()
  end
end
