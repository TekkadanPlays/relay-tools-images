defmodule GcIndexRelayWeb.AdminController do
  @moduledoc """
  Admin-only endpoints for site management.

  All routes require the `:admin` role (enforced by the `RequireRole` plug
  in the router pipeline). Authentication is via API key or Phoenix.Token.

  ## Endpoints

  - `GET  /api/admin/stats`          — Event counts, storage, admin list
  - `DELETE /api/admin/events/purge` — Delete ALL events (nuclear option)
  - `POST /api/admin/ban`            — Ban a pubkey (site-wide or community-scoped)
  - `DELETE /api/admin/ban/:pubkey`  — Unban a pubkey
  - `GET  /api/admin/bans`           — List all active bans
  - `GET  /api/admin/admins`         — List all site admins
  """

  use GcIndexRelayWeb, :controller

  import Ecto.Query
  alias GcIndexRelay.Repo
  alias GcIndexRelay.Nostr.Event
  alias GcIndexRelay.Auth.Roles

  @doc """
  Returns instance statistics: event count, event count by kind,
  admin count, ban count, and database size estimate.
  """
  def stats(conn, _params) do
    total_events = Repo.aggregate(Event, :count)

    # Top 10 kinds by event count
    kind_counts =
      from(e in Event,
        group_by: e.kind,
        select: {e.kind, count(e.id)},
        order_by: [desc: count(e.id)],
        limit: 10
      )
      |> Repo.all()
      |> Enum.map(fn {kind, count} -> %{kind: kind, count: count} end)

    admins = Roles.list_admins()
    bans = Roles.list_bans()

    conn
    |> put_status(:ok)
    |> json(%{
      ok: true,
      stats: %{
        total_events: total_events,
        events_by_kind: kind_counts,
        admin_count: length(admins),
        active_ban_count: length(bans),
      }
    })
  end

  @doc """
  Delete ALL events from the relay. This is the nuclear option.
  Requires confirmation via `"confirm": "PURGE ALL EVENTS"` in the body.
  """
  def purge_events(conn, %{"confirm" => "PURGE ALL EVENTS"}) do
    {deleted, _} = Repo.delete_all(Event)

    conn
    |> put_status(:ok)
    |> json(%{
      ok: true,
      message: "Purged all events",
      deleted_count: deleted
    })
  end

  def purge_events(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Must include {\"confirm\": \"PURGE ALL EVENTS\"} to proceed"})
  end

  @doc """
  Ban a pubkey. Accepts:

  ```json
  {
    "pubkey": "<64-char-hex>",
    "scope": "34550:...:CommunityName",  // optional, null = site-wide
    "reason": "spam",                    // optional
    "duration_hours": 24                 // optional, null = permanent
  }
  ```
  """
  def ban(conn, %{"pubkey" => pubkey} = params) do
    admin_pubkey = conn.assigns[:current_pubkey]
    scope = Map.get(params, "scope")
    reason = Map.get(params, "reason")

    expires_at =
      case Map.get(params, "duration_hours") do
        nil -> nil
        hours when is_number(hours) ->
          DateTime.utc_now()
          |> DateTime.add(round(hours * 3600), :second)
          |> DateTime.truncate(:second)
        _ -> nil
      end

    case Roles.ban_user(pubkey, admin_pubkey, scope, reason, expires_at) do
      {:ok, ban} ->
        conn
        |> put_status(:created)
        |> json(%{
          ok: true,
          message: "User banned",
          ban: %{
            pubkey: ban.pubkey,
            scope: ban.scope || "site-wide",
            reason: ban.reason,
            expires_at: ban.expires_at && DateTime.to_iso8601(ban.expires_at),
            banned_by: ban.banned_by
          }
        })

      {:error, %Ecto.Changeset{} = cs} ->
        errors = Ecto.Changeset.traverse_errors(cs, fn {msg, _opts} -> msg end)
        conn |> put_status(:unprocessable_entity) |> json(%{error: "Validation failed", details: errors})
    end
  end

  def ban(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{error: "Missing 'pubkey' parameter"})
  end

  @doc """
  Unban a pubkey. Scope is passed as a query parameter:
  `DELETE /api/admin/ban/:pubkey?scope=34550:...:CommunityName`
  Omit `scope` for site-wide unban.
  """
  def unban(conn, %{"pubkey" => pubkey} = params) do
    scope = Map.get(params, "scope")
    {deleted, _} = Roles.unban_user(pubkey, scope)

    if deleted > 0 do
      conn |> put_status(:ok) |> json(%{ok: true, message: "User unbanned"})
    else
      conn |> put_status(:not_found) |> json(%{error: "No matching ban found"})
    end
  end

  @doc """
  List all active (unexpired) bans.
  """
  def list_bans(conn, _params) do
    bans =
      Roles.list_bans()
      |> Enum.map(fn b ->
        %{
          pubkey: b.pubkey,
          scope: b.scope || "site-wide",
          reason: b.reason,
          banned_by: b.banned_by,
          expires_at: b.expires_at && DateTime.to_iso8601(b.expires_at),
          created_at: DateTime.to_iso8601(b.inserted_at)
        }
      end)

    conn |> put_status(:ok) |> json(%{ok: true, bans: bans})
  end

  @doc """
  List all site admins (DB + env override).
  """
  def list_admins(conn, _params) do
    admins =
      Roles.list_admins()
      |> Enum.map(fn a ->
        %{
          pubkey: a.pubkey,
          label: a.label,
          source: a.source,
          claimed_at: a.claimed_at && DateTime.to_iso8601(a.claimed_at)
        }
      end)

    conn |> put_status(:ok) |> json(%{ok: true, admins: admins})
  end

  @doc """
  Appoint a community moderator.

  Body: `{ "pubkey": "...", "community_atag": "34550:..." }`
  """
  def appoint_mod(conn, %{"pubkey" => pubkey, "community_atag" => community_atag}) do
    admin_pubkey = conn.assigns[:current_pubkey]

    case Roles.appoint_mod(pubkey, community_atag, admin_pubkey) do
      {:ok, mod} ->
        conn
        |> put_status(:created)
        |> json(%{
          ok: true,
          message: "Moderator appointed",
          moderator: %{
            pubkey: mod.pubkey,
            community: mod.community_atag,
            appointed_by: mod.appointed_by
          }
        })

      {:error, %Ecto.Changeset{} = cs} ->
        errors = Ecto.Changeset.traverse_errors(cs, fn {msg, _} -> msg end)
        conn |> put_status(:unprocessable_entity) |> json(%{error: "Failed", details: errors})
    end
  end

  def appoint_mod(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{error: "Missing 'pubkey' and 'community_atag'"})
  end

  @doc """
  Remove a community moderator.
  `DELETE /api/admin/moderators/:pubkey/:community_atag`
  """
  def remove_mod(conn, %{"pubkey" => pubkey, "community_atag" => community_atag}) do
    {deleted, _} = Roles.remove_mod(pubkey, community_atag)

    if deleted > 0 do
      conn |> put_status(:ok) |> json(%{ok: true, message: "Moderator removed"})
    else
      conn |> put_status(:not_found) |> json(%{error: "Moderator not found"})
    end
  end

  @doc """
  List all community moderators. Optional filter: `?community_atag=34550:...`
  """
  def list_mods(conn, params) do
    community_filter = Map.get(params, "community_atag")

    mods =
      Roles.list_mods(community_filter)
      |> Enum.map(fn m ->
        %{
          pubkey: m.pubkey,
          community: m.community_atag,
          appointed_by: m.appointed_by,
          appointed_at: m.appointed_at && DateTime.to_iso8601(m.appointed_at)
        }
      end)

    conn |> put_status(:ok) |> json(%{ok: true, moderators: mods})
  end
end
