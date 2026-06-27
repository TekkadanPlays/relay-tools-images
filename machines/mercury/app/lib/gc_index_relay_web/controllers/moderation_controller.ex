defmodule GcIndexRelayWeb.ModerationController do
  @moduledoc """
  Moderation endpoints for community moderators and site admins.

  Community moderators can manage events and reports within their
  assigned communities. Site admins have global mod privileges.

  ## Endpoints

  - `POST   /api/mod/hide/:event_id`      — Soft-delete an event (hide from feeds)
  - `POST   /api/mod/unhide/:event_id`     — Restore a hidden event
  - `POST   /api/mod/ban`                  — Community-scoped ban
  - `DELETE /api/mod/ban/:pubkey`           — Community unban
  - `POST   /api/mod/report`               — File a report
  - `GET    /api/mod/reports`              — List reports (filtered for mods)
  - `POST   /api/mod/reports/:id/resolve`  — Resolve a report
  - `GET    /api/mod/hidden`               — List hidden events
  """

  use GcIndexRelayWeb, :controller

  import Ecto.Query
  alias GcIndexRelay.Repo
  alias GcIndexRelay.Auth.Roles
  alias GcIndexRelay.Nostr.HiddenEvent
  alias GcIndexRelay.Nostr.Report

  @doc """
  Hide an event from feeds (soft-delete).
  Mods can hide events in their community; admins can hide any event.

  Body: `{ "community_atag": "34550:...", "reason": "spam" }`
  """
  def hide_event(conn, %{"event_id" => event_id} = params) do
    pubkey = conn.assigns[:current_pubkey]
    community = Map.get(params, "community_atag")
    reason = Map.get(params, "reason")

    with :ok <- authorize_mod(pubkey, community) do
      changeset = HiddenEvent.changeset(%HiddenEvent{}, %{
        event_id: event_id,
        hidden_by: pubkey,
        community_atag: community,
        reason: reason,
        hidden_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

      case Repo.insert(changeset, on_conflict: :nothing) do
        {:ok, _} ->
          conn |> put_status(:ok) |> json(%{ok: true, message: "Event hidden", event_id: event_id})

        {:error, cs} ->
          errors = Ecto.Changeset.traverse_errors(cs, fn {msg, _} -> msg end)
          conn |> put_status(:unprocessable_entity) |> json(%{error: "Failed to hide", details: errors})
      end
    end
  end

  @doc """
  Restore a hidden event (un-hide).
  """
  def unhide_event(conn, %{"event_id" => event_id} = params) do
    pubkey = conn.assigns[:current_pubkey]
    community = Map.get(params, "community_atag")

    with :ok <- authorize_mod(pubkey, community) do
      {deleted, _} =
        from(h in HiddenEvent, where: h.event_id == ^event_id)
        |> Repo.delete_all()

      if deleted > 0 do
        conn |> put_status(:ok) |> json(%{ok: true, message: "Event restored", event_id: event_id})
      else
        conn |> put_status(:not_found) |> json(%{error: "Event not found in hidden list"})
      end
    end
  end

  @doc """
  Community-scoped ban. Requires mod privileges for the community.

  Body: `{ "pubkey": "...", "community_atag": "34550:...", "reason": "...", "duration_hours": 24 }`
  """
  def ban(conn, %{"pubkey" => target_pubkey, "community_atag" => community} = params) do
    mod_pubkey = conn.assigns[:current_pubkey]
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

    with :ok <- authorize_mod(mod_pubkey, community) do
      case Roles.ban_user(target_pubkey, mod_pubkey, community, reason, expires_at) do
        {:ok, ban} ->
          conn
          |> put_status(:created)
          |> json(%{
            ok: true,
            message: "User banned from community",
            ban: %{
              pubkey: ban.pubkey,
              community: ban.scope,
              reason: ban.reason,
              expires_at: ban.expires_at && DateTime.to_iso8601(ban.expires_at)
            }
          })

        {:error, cs} ->
          errors = Ecto.Changeset.traverse_errors(cs, fn {msg, _} -> msg end)
          conn |> put_status(:unprocessable_entity) |> json(%{error: "Ban failed", details: errors})
      end
    end
  end

  def ban(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{error: "Missing 'pubkey' and 'community_atag' parameters"})
  end

  @doc """
  Remove a community ban.
  `DELETE /api/mod/ban/:pubkey?community_atag=34550:...`
  """
  def unban(conn, %{"pubkey" => target_pubkey} = params) do
    mod_pubkey = conn.assigns[:current_pubkey]
    community = Map.get(params, "community_atag")

    with :ok <- authorize_mod(mod_pubkey, community) do
      {deleted, _} = Roles.unban_user(target_pubkey, community)

      if deleted > 0 do
        conn |> put_status(:ok) |> json(%{ok: true, message: "User unbanned"})
      else
        conn |> put_status(:not_found) |> json(%{error: "No matching ban found"})
      end
    end
  end

  @doc """
  File a report against an event. Any authenticated user can report.

  Body: `{ "event_id": "...", "reason": "spam", "community_atag": "34550:..." }`
  """
  def create_report(conn, %{"event_id" => event_id, "reason" => reason} = params) do
    reporter = conn.assigns[:current_pubkey]
    community = Map.get(params, "community_atag")

    changeset = Report.changeset(%Report{}, %{
      event_id: event_id,
      reporter_pubkey: reporter,
      community_atag: community,
      reason: reason
    })

    case Repo.insert(changeset) do
      {:ok, report} ->
        conn
        |> put_status(:created)
        |> json(%{ok: true, message: "Report filed", report_id: report.id})

      {:error, cs} ->
        errors = Ecto.Changeset.traverse_errors(cs, fn {msg, _} -> msg end)
        conn |> put_status(:unprocessable_entity) |> json(%{error: "Report failed", details: errors})
    end
  end

  def create_report(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{error: "Missing 'event_id' and 'reason' parameters"})
  end

  @doc """
  List reports. Admins see all; mods see their communities only.
  Query params: `?status=pending&community_atag=34550:...`
  """
  def list_reports(conn, params) do
    pubkey = conn.assigns[:current_pubkey]
    status_filter = Map.get(params, "status")
    community_filter = Map.get(params, "community_atag")

    query = from(r in Report, order_by: [desc: r.inserted_at])

    # Filter by status if provided
    query = if status_filter, do: from(r in query, where: r.status == ^status_filter), else: query

    # Non-admin mods can only see their community reports
    query =
      if Roles.is_admin?(pubkey) do
        if community_filter do
          from(r in query, where: r.community_atag == ^community_filter)
        else
          query
        end
      else
        # Mod: only their communities
        mod_communities =
          Roles.list_mods()
          |> Enum.filter(&(&1.pubkey == String.downcase(pubkey)))
          |> Enum.map(& &1.community_atag)

        from(r in query, where: r.community_atag in ^mod_communities)
      end

    reports =
      Repo.all(query)
      |> Enum.map(fn r ->
        %{
          id: r.id,
          event_id: r.event_id,
          reporter: r.reporter_pubkey,
          community: r.community_atag,
          reason: r.reason,
          status: r.status,
          resolved_by: r.resolved_by,
          resolved_at: r.resolved_at && DateTime.to_iso8601(r.resolved_at),
          created_at: DateTime.to_iso8601(r.inserted_at)
        }
      end)

    conn |> put_status(:ok) |> json(%{ok: true, reports: reports})
  end

  @doc """
  Resolve a report. Action must be "approved" or "dismissed".

  Body: `{ "action": "approved" }` or `{ "action": "dismissed" }`
  """
  def resolve_report(conn, %{"id" => id, "action" => action})
      when action in ["approved", "dismissed"] do
    pubkey = conn.assigns[:current_pubkey]

    case Repo.get(Report, id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Report not found"})

      report ->
        with :ok <- authorize_mod(pubkey, report.community_atag) do
          changeset =
            report
            |> Report.changeset(%{
              status: action,
              resolved_by: pubkey,
              resolved_at: DateTime.utc_now() |> DateTime.truncate(:second)
            })

          case Repo.update(changeset) do
            {:ok, updated} ->
              # If approved, auto-hide the reported event
              if action == "approved" do
                Repo.insert(
                  %HiddenEvent{}
                  |> HiddenEvent.changeset(%{
                    event_id: updated.event_id,
                    hidden_by: pubkey,
                    community_atag: updated.community_atag,
                    reason: "Report ##{updated.id} approved: #{updated.reason}",
                    hidden_at: DateTime.utc_now() |> DateTime.truncate(:second)
                  }),
                  on_conflict: :nothing
                )
              end

              conn |> put_status(:ok) |> json(%{
                ok: true,
                message: "Report #{action}",
                report_id: updated.id
              })

            {:error, cs} ->
              errors = Ecto.Changeset.traverse_errors(cs, fn {msg, _} -> msg end)
              conn |> put_status(:unprocessable_entity) |> json(%{error: "Update failed", details: errors})
          end
        end
    end
  end

  def resolve_report(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{error: "Missing 'id' and 'action' (approved|dismissed)"})
  end

  @doc """
  List hidden events. Admins see all; mods see their community.
  """
  def list_hidden(conn, params) do
    pubkey = conn.assigns[:current_pubkey]
    community_filter = Map.get(params, "community_atag")

    query = from(h in HiddenEvent, order_by: [desc: h.hidden_at])

    query =
      if Roles.is_admin?(pubkey) do
        if community_filter do
          from(h in query, where: h.community_atag == ^community_filter)
        else
          query
        end
      else
        mod_communities =
          Roles.list_mods()
          |> Enum.filter(&(&1.pubkey == String.downcase(pubkey)))
          |> Enum.map(& &1.community_atag)

        from(h in query, where: h.community_atag in ^mod_communities)
      end

    hidden =
      Repo.all(query)
      |> Enum.map(fn h ->
        %{
          event_id: h.event_id,
          hidden_by: h.hidden_by,
          community: h.community_atag,
          reason: h.reason,
          hidden_at: h.hidden_at && DateTime.to_iso8601(h.hidden_at)
        }
      end)

    conn |> put_status(:ok) |> json(%{ok: true, hidden: hidden})
  end

  # ── Authorization helper ──

  defp authorize_mod(pubkey, community_atag) do
    cond do
      Roles.is_admin?(pubkey) ->
        :ok
      community_atag != nil and Roles.is_mod?(pubkey, community_atag) ->
        :ok
      community_atag == nil ->
        {:error, :missing_community}
      true ->
        {:error, :forbidden}
    end
    |> case do
      :ok -> :ok
      {:error, :missing_community} ->
        raise Phoenix.ActionClauseError, message: "community_atag required for mod actions"
      {:error, :forbidden} ->
        raise Phoenix.ActionClauseError, message: "Not authorized for this community"
    end
  end
end
