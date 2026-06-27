defmodule GcIndexRelayWeb.FederationController do
  @moduledoc """
  Federation API endpoints for managing sync agreements.

  Admins and community mods can create, approve, and manage sync
  agreements between communities (local or cross-instance).

  ## Endpoints

  - `POST   /api/federation/agreements`       — Create a sync agreement
  - `GET    /api/federation/agreements`        — List all agreements
  - `GET    /api/federation/agreements/:id`    — Get agreement details
  - `PUT    /api/federation/agreements/:id`    — Update (pause/resume/change interval)
  - `DELETE /api/federation/agreements/:id`    — Cancel agreement
  - `POST   /api/federation/agreements/:id/approve` — Approve a pending agreement
  - `POST   /api/federation/agreements/:id/reject`  — Reject a pending agreement
  - `POST   /api/federation/sync/:id`         — Force immediate sync
  """

  use GcIndexRelayWeb, :controller

  import Ecto.Query
  alias GcIndexRelay.Repo
  alias GcIndexRelay.Auth.Roles
  alias GcIndexRelay.Federation.SyncAgreement
  alias GcIndexRelay.Federation.SyncWorker

  @doc """
  Create a new sync agreement.

  Body:
  ```json
  {
    "source_instance_url": "https://api.example.social",  // null = local
    "source_community": "34550:<pk>:ZeroWaste",
    "dest_instance_url": null,                              // null = local
    "dest_community": "34550:<pk>:ZeroWasteGardening",
    "direction": "pull",                                    // pull | push | bidirectional
    "sync_interval_sec": 300                                // min 60
  }
  ```
  """
  def create(conn, params) do
    pubkey = conn.assigns[:current_pubkey]

    # Verify the requester has mod/admin rights on the destination community
    dest_community = Map.get(params, "dest_community", "")
    unless Roles.is_admin?(pubkey) or Roles.is_mod?(pubkey, dest_community) do
      conn |> put_status(:forbidden) |> json(%{error: "Not authorized for destination community"})
      |> halt()
    end

    # For local agreements, auto-approve. Cross-instance = pending.
    is_local = is_nil(Map.get(params, "source_instance_url")) and
               is_nil(Map.get(params, "dest_instance_url"))

    status = if is_local, do: "active", else: "pending"
    sync_key = if is_local, do: nil, else: generate_sync_key()

    changeset = SyncAgreement.changeset(%SyncAgreement{}, %{
      source_instance_url: Map.get(params, "source_instance_url"),
      source_community: Map.get(params, "source_community"),
      dest_instance_url: Map.get(params, "dest_instance_url"),
      dest_community: Map.get(params, "dest_community"),
      direction: Map.get(params, "direction", "pull"),
      status: status,
      requested_by: pubkey,
      approved_by: if(is_local, do: pubkey, else: nil),
      sync_interval_sec: Map.get(params, "sync_interval_sec", 300),
      sync_api_key: sync_key
    })

    case Repo.insert(changeset) do
      {:ok, agreement} ->
        conn
        |> put_status(:created)
        |> json(%{
          ok: true,
          message: if(is_local, do: "Local sync agreement created (auto-approved)", else: "Sync agreement created (pending approval)"),
          agreement: serialize_agreement(agreement)
        })

      {:error, cs} ->
        errors = Ecto.Changeset.traverse_errors(cs, fn {msg, _} -> msg end)
        conn |> put_status(:unprocessable_entity) |> json(%{error: "Validation failed", details: errors})
    end
  end

  @doc "List all sync agreements. Optional filter: ?status=active"
  def index(conn, params) do
    status_filter = Map.get(params, "status")

    query = from(a in SyncAgreement, order_by: [desc: a.inserted_at])
    query = if status_filter, do: from(a in query, where: a.status == ^status_filter), else: query

    agreements = Repo.all(query) |> Enum.map(&serialize_agreement/1)

    conn |> put_status(:ok) |> json(%{ok: true, agreements: agreements})
  end

  @doc "Get a single agreement by ID."
  def show(conn, %{"id" => id}) do
    case Repo.get(SyncAgreement, id) do
      nil -> conn |> put_status(:not_found) |> json(%{error: "Agreement not found"})
      agreement -> conn |> put_status(:ok) |> json(%{ok: true, agreement: serialize_agreement(agreement)})
    end
  end

  @doc """
  Update an agreement. Supports:
  - `status`: "paused" or "active" (for pause/resume)
  - `sync_interval_sec`: change sync frequency
  """
  def update(conn, %{"id" => id} = params) do
    case Repo.get(SyncAgreement, id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Agreement not found"})

      agreement ->
        allowed_updates = Map.take(params, ["status", "sync_interval_sec"])

        case agreement |> SyncAgreement.changeset(atomize_keys(allowed_updates)) |> Repo.update() do
          {:ok, updated} ->
            conn |> put_status(:ok) |> json(%{ok: true, agreement: serialize_agreement(updated)})

          {:error, cs} ->
            errors = Ecto.Changeset.traverse_errors(cs, fn {msg, _} -> msg end)
            conn |> put_status(:unprocessable_entity) |> json(%{error: "Update failed", details: errors})
        end
    end
  end

  @doc "Cancel (delete) an agreement."
  def delete(conn, %{"id" => id}) do
    case Repo.get(SyncAgreement, id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Agreement not found"})

      agreement ->
        case agreement |> SyncAgreement.changeset(%{status: "cancelled"}) |> Repo.update() do
          {:ok, _} -> conn |> put_status(:ok) |> json(%{ok: true, message: "Agreement cancelled"})
          {:error, _} -> conn |> put_status(:internal_server_error) |> json(%{error: "Failed to cancel"})
        end
    end
  end

  @doc "Approve a pending agreement (for incoming cross-instance requests)."
  def approve(conn, %{"id" => id}) do
    pubkey = conn.assigns[:current_pubkey]

    case Repo.get(SyncAgreement, id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Agreement not found"})

      %{status: "pending"} = agreement ->
        case agreement |> SyncAgreement.changeset(%{
          status: "active",
          approved_by: pubkey,
          sync_api_key: agreement.sync_api_key || generate_sync_key()
        }) |> Repo.update() do
          {:ok, updated} ->
            conn |> put_status(:ok) |> json(%{
              ok: true,
              message: "Agreement approved",
              agreement: serialize_agreement(updated)
            })
          {:error, _} ->
            conn |> put_status(:internal_server_error) |> json(%{error: "Failed to approve"})
        end

      _ ->
        conn |> put_status(:conflict) |> json(%{error: "Agreement is not in pending status"})
    end
  end

  @doc "Reject a pending agreement."
  def reject(conn, %{"id" => id}) do
    case Repo.get(SyncAgreement, id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Agreement not found"})

      %{status: "pending"} = agreement ->
        case agreement |> SyncAgreement.changeset(%{status: "rejected"}) |> Repo.update() do
          {:ok, _} -> conn |> put_status(:ok) |> json(%{ok: true, message: "Agreement rejected"})
          {:error, _} -> conn |> put_status(:internal_server_error) |> json(%{error: "Failed to reject"})
        end

      _ ->
        conn |> put_status(:conflict) |> json(%{error: "Agreement is not in pending status"})
    end
  end

  @doc "Force an immediate sync for a specific agreement."
  def force_sync(conn, %{"id" => _id}) do
    SyncWorker.sync_now()
    conn |> put_status(:ok) |> json(%{ok: true, message: "Sync cycle triggered"})
  end

  # ── Helpers ──

  defp serialize_agreement(a) do
    %{
      id: a.id,
      source_instance_url: a.source_instance_url,
      source_community: a.source_community,
      dest_instance_url: a.dest_instance_url,
      dest_community: a.dest_community,
      direction: a.direction,
      status: a.status,
      local: SyncAgreement.local?(a),
      requested_by: a.requested_by,
      approved_by: a.approved_by,
      sync_interval_sec: a.sync_interval_sec,
      last_synced_at: a.last_synced_at && DateTime.to_iso8601(a.last_synced_at),
      created_at: a.inserted_at && DateTime.to_iso8601(a.inserted_at)
    }
  end

  defp generate_sync_key do
    "sync_" <> (:crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false))
  end

  defp atomize_keys(map) do
    Map.new(map, fn {k, v} -> {String.to_existing_atom(k), v} end)
  rescue
    ArgumentError -> %{}
  end
end
