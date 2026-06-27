defmodule GcIndexRelay.Federation.SyncWorker do
  @moduledoc """
  GenServer that periodically syncs content between communities
  based on active sync agreements.

  ## Tick Cycle

  Every 30 seconds, the worker checks all active agreements and
  runs any that are due (based on their `sync_interval_sec` and
  `last_synced_at`). This avoids spawning a separate timer per
  agreement.

  ## Sync Strategies

  - **Local sync:** Both source and dest are on this instance.
    Query source community events → re-tag → insert into dest.
  - **Remote pull:** Fetch events from a remote instance's REST API
    using the agreement's scoped `sync_api_key`.
  - **Remote push:** Send local events to a remote instance's
    event creation endpoint.
  """

  use GenServer
  require Logger

  import Ecto.Query
  alias GcIndexRelay.Repo
  alias GcIndexRelay.Federation.SyncAgreement
  alias GcIndexRelay.Federation.SyncProtocol

  @tick_interval_ms 30_000  # Check agreements every 30s

  # ── Client API ──

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Force an immediate sync cycle (useful for testing)."
  def sync_now do
    GenServer.cast(__MODULE__, :sync_now)
  end

  # ── Server Callbacks ──

  @impl true
  def init(_opts) do
    Logger.info("[SyncWorker] Starting federation sync worker")
    schedule_tick()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    run_sync_cycle()
    schedule_tick()
    {:noreply, state}
  end

  @impl true
  def handle_cast(:sync_now, state) do
    run_sync_cycle()
    {:noreply, state}
  end

  # ── Sync Logic ──

  defp schedule_tick do
    Process.send_after(self(), :tick, @tick_interval_ms)
  end

  defp run_sync_cycle do
    now = DateTime.utc_now()

    active_agreements()
    |> Enum.filter(&due_for_sync?(&1, now))
    |> Enum.each(fn agreement ->
      try do
        sync_agreement(agreement)
      rescue
        e ->
          Logger.error("[SyncWorker] Error syncing agreement ##{agreement.id}: #{Exception.message(e)}")
      end
    end)
  end

  defp active_agreements do
    from(a in SyncAgreement, where: a.status == "active")
    |> Repo.all()
  end

  defp due_for_sync?(%SyncAgreement{last_synced_at: nil}, _now), do: true

  defp due_for_sync?(%SyncAgreement{last_synced_at: last, sync_interval_sec: interval}, now) do
    DateTime.diff(now, last, :second) >= interval
  end

  defp sync_agreement(%SyncAgreement{} = agreement) do
    Logger.info("[SyncWorker] Syncing agreement ##{agreement.id}: " <>
      "#{agreement.source_community} → #{agreement.dest_community} (#{agreement.direction})")

    result =
      if SyncAgreement.local?(agreement) do
        sync_local(agreement)
      else
        sync_remote(agreement)
      end

    # Update last_synced_at regardless of result
    agreement
    |> SyncAgreement.changeset(%{last_synced_at: DateTime.utc_now() |> DateTime.truncate(:second)})
    |> Repo.update()

    case result do
      {:ok, count} ->
        Logger.info("[SyncWorker] Agreement ##{agreement.id}: synced #{count} events")
      {:error, reason} ->
        Logger.warning("[SyncWorker] Agreement ##{agreement.id} failed: #{inspect(reason)}")
    end
  end

  # ── Local (intra-instance) sync ──

  defp sync_local(agreement) do
    alias GcIndexRelay.Nostr.Event
    alias GcIndexRelay.Nostr.Tag
    alias GcIndexRelay.Nostr.PubEvent

    # Find events in source community that aren't already in dest
    source_events = query_community_events(
      agreement.source_community,
      agreement.last_sync_cursor
    )

    synced = 0
    latest_cursor = agreement.last_sync_cursor

    result =
      Enum.reduce(source_events, {0, latest_cursor}, fn event, {count, cursor} ->
        # Check if this event already has the dest community tag
        has_dest_tag = Enum.any?(event.tags, fn
          %{name: "a", value: value} -> value == agreement.dest_community
          _ -> false
        end)

        unless has_dest_tag do
          # Add the destination community tag
          %Tag{}
          |> Tag.changeset(%{
            name: "a",
            value: agreement.dest_community,
            event_id: event.id
          })
          |> Repo.insert(on_conflict: :nothing)
        end

        new_cursor =
          if event.created_at && (cursor == nil || DateTime.compare(event.created_at, cursor) == :gt) do
            event.created_at
          else
            cursor
          end

        {count + 1, new_cursor}
      end)

    {synced_count, new_cursor} = result

    # Update cursor
    if new_cursor do
      agreement
      |> SyncAgreement.changeset(%{last_sync_cursor: new_cursor})
      |> Repo.update()
    end

    {:ok, synced_count}
  end

  # ── Remote sync ──

  defp sync_remote(agreement) do
    case agreement.direction do
      "pull" ->
        SyncProtocol.pull_from_remote(agreement)

      "push" ->
        SyncProtocol.push_to_remote(agreement)

      "bidirectional" ->
        with {:ok, pulled} <- SyncProtocol.pull_from_remote(agreement),
             {:ok, pushed} <- SyncProtocol.push_to_remote(agreement) do
          {:ok, pulled + pushed}
        end
    end
  end

  # ── Helpers ──

  defp query_community_events(community_atag, since_cursor) do
    alias GcIndexRelay.Nostr.Event
    alias GcIndexRelay.Nostr.Tag

    query =
      from e in Event,
        join: t in Tag, on: t.event_id == e.id,
        where: t.name == "a" and t.value == ^community_atag,
        preload: [:tags],
        order_by: [asc: e.created_at],
        limit: 500

    query =
      if since_cursor do
        from e in query, where: e.created_at > ^since_cursor
      else
        query
      end

    Repo.all(query)
  end
end
