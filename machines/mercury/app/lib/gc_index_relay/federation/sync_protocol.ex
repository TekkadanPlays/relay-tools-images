defmodule GcIndexRelay.Federation.SyncProtocol do
  @moduledoc """
  HTTP protocol for cross-instance federation sync.

  Uses Erlang's built-in `:httpc` (from `:inets`) — no additional
  dependencies required. Communicates with remote Mercury instances
  via their existing REST API.

  ## Pull Flow

  1. POST remote `/api/events/filter` with community filter + since cursor
  2. Receive events as JSON
  3. Insert into local DB with destination community tag

  ## Push Flow

  1. Query local events for the source community
  2. POST each to remote `/api/events` endpoint
  """

  require Logger
  import Ecto.Query

  alias GcIndexRelay.Repo
  alias GcIndexRelay.Nostr
  alias GcIndexRelay.Nostr.PubEvent
  alias GcIndexRelay.Federation.SyncAgreement

  @request_timeout_ms 15_000

  @doc """
  Pull events from a remote instance for the given agreement.
  """
  def pull_from_remote(%SyncAgreement{} = agreement) do
    source_url = agreement.source_instance_url
    community = agreement.source_community

    # Build the filter
    filter = %{
      "#a" => [community],
      "limit" => 200
    }

    filter =
      if agreement.last_sync_cursor do
        Map.put(filter, "since", DateTime.to_unix(agreement.last_sync_cursor))
      else
        filter
      end

    # POST to remote /api/events/filter
    url = "#{source_url}/api/events/filter"
    headers = build_headers(agreement.sync_api_key)

    case http_post_json(url, filter, headers) do
      {:ok, %{"data" => events}} when is_list(events) ->
        insert_remote_events(events, agreement)

      {:ok, events} when is_list(events) ->
        insert_remote_events(events, agreement)

      {:ok, other} ->
        Logger.warning("[SyncProtocol] Unexpected response from #{url}: #{inspect(other)}")
        {:error, :unexpected_response}

      {:error, reason} ->
        Logger.error("[SyncProtocol] Pull failed from #{url}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Push local events to a remote instance for the given agreement.
  """
  def push_to_remote(%SyncAgreement{} = agreement) do
    dest_url = agreement.dest_instance_url
    community = agreement.source_community
    headers = build_headers(agreement.sync_api_key)

    # Query local events for this community
    events = query_local_events(community, agreement.last_sync_cursor)

    pushed =
      Enum.reduce(events, 0, fn event, count ->
        case push_single_event(dest_url, event, agreement.dest_community, headers) do
          :ok -> count + 1
          :error -> count
        end
      end)

    # Update cursor to latest event
    if length(events) > 0 do
      latest = events |> Enum.max_by(& &1.created_at) |> Map.get(:created_at)
      if latest do
        agreement
        |> SyncAgreement.changeset(%{last_sync_cursor: latest})
        |> Repo.update()
      end
    end

    {:ok, pushed}
  end

  # ── Private ──

  defp insert_remote_events(events, agreement) do
    inserted =
      Enum.reduce(events, 0, fn event_map, count ->
        # Add destination community tag if not present
        tags = Map.get(event_map, "tags", [])
        has_dest = Enum.any?(tags, fn
          ["a", value | _] -> value == agreement.dest_community
          _ -> false
        end)

        tags = if has_dest, do: tags, else: tags ++ [["a", agreement.dest_community]]

        pub_event = %PubEvent{
          id: Map.get(event_map, "id"),
          pubkey: Map.get(event_map, "pubkey"),
          created_at: Map.get(event_map, "created_at"),
          kind: Map.get(event_map, "kind"),
          tags: tags,
          content: Map.get(event_map, "content", ""),
          sig: Map.get(event_map, "sig")
        }

        case Nostr.create_event(pub_event) do
          {:ok, _} -> count + 1
          {:error, _} -> count  # Duplicate or validation failure, skip
        end
      end)

    # Update cursor
    if length(events) > 0 do
      latest_ts =
        events
        |> Enum.map(&Map.get(&1, "created_at", 0))
        |> Enum.max()

      if is_integer(latest_ts) and latest_ts > 0 do
        cursor = DateTime.from_unix!(latest_ts) |> DateTime.truncate(:second)
        agreement
        |> SyncAgreement.changeset(%{last_sync_cursor: cursor})
        |> Repo.update()
      end
    end

    {:ok, inserted}
  end

  defp push_single_event(dest_url, event, dest_community, headers) do
    # Convert DB event to publishable format with dest community tag
    case PubEvent.from_db(Repo.preload(event, :tags)) do
      {:ok, pub_event} ->
        tags = pub_event.tags ++ [["a", dest_community]]
        payload = %{
          "event" => %{
            "id" => pub_event.id,
            "pubkey" => pub_event.pubkey,
            "created_at" => pub_event.created_at,
            "kind" => pub_event.kind,
            "tags" => tags,
            "content" => pub_event.content,
            "sig" => pub_event.sig
          }
        }

        url = "#{dest_url}/api/events"
        case http_post_json(url, payload, headers) do
          {:ok, _} -> :ok
          {:error, _} -> :error
        end

      {:error, _} ->
        :error
    end
  end

  defp query_local_events(community, since_cursor) do
    alias GcIndexRelay.Nostr.Event
    alias GcIndexRelay.Nostr.Tag

    query =
      from e in Event,
        join: t in Tag, on: t.event_id == e.id,
        where: t.name == "a" and t.value == ^community,
        order_by: [asc: e.created_at],
        limit: 200

    query =
      if since_cursor do
        from e in query, where: e.created_at > ^since_cursor
      else
        query
      end

    Repo.all(query)
  end

  defp build_headers(nil), do: []
  defp build_headers(api_key) do
    [{~c"authorization", String.to_charlist("Bearer #{api_key}")}]
  end

  defp http_post_json(url, body, extra_headers) do
    # Ensure :inets is started
    :inets.start()
    :ssl.start()

    json_body = Jason.encode!(body)
    url_charlist = String.to_charlist(url)

    headers = [{~c"content-type", ~c"application/json"} | extra_headers]

    case :httpc.request(
      :post,
      {url_charlist, headers, ~c"application/json", json_body},
      [timeout: @request_timeout_ms, ssl: [verify: :verify_none]],
      []
    ) do
      {:ok, {{_, status, _}, _resp_headers, resp_body}} when status in 200..299 ->
        case Jason.decode(to_string(resp_body)) do
          {:ok, parsed} -> {:ok, parsed}
          {:error, _} -> {:ok, to_string(resp_body)}
        end

      {:ok, {{_, status, _}, _, resp_body}} ->
        {:error, {:http_error, status, to_string(resp_body)}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end
end
