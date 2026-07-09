defmodule GcIndexRelayWeb.NostrSocket do
  @behaviour WebSock

  alias GcIndexRelay.Nostr
  alias GcIndexRelay.Nostr.PubEvent
  alias GcIndexRelay.Nostr.Filter
  require Logger

  @impl true
  def init(_args) do
    {:ok, %{subs: %{}}}
  end

  @impl true
  def handle_in({text, [opcode: :text]}, state) do
    case Jason.decode(text) do
      {:ok, ["REQ", sub_id | filters]} ->
        handle_req(sub_id, filters, state)

      {:ok, ["EVENT", event_map]} ->
        handle_event(event_map, state)

      {:ok, ["CLOSE", sub_id]} ->
        handle_close(sub_id, state)

      _ ->
        {:push, [{:text, Jason.encode!(["NOTICE", "invalid message"])}], state}
    end
  end

  def handle_in(_, state), do: {:ok, state}

  defp handle_req(sub_id, filters, state) do
    if map_size(state.subs) == 0 do
      Phoenix.PubSub.subscribe(GcIndexRelay.PubSub, "events")
    end

    parsed_filters =
      filters
      |> Enum.map(&Filter.from_map/1)
      |> Enum.filter(&match?({:ok, _}, &1))
      |> Enum.map(fn {:ok, filter} -> filter end)

    state = put_in(state.subs[sub_id], parsed_filters)

    history_replies =
      Enum.flat_map(filters, fn filter_map ->
        db_events =
          case Nostr.query_events(filter_map) do
            {:ok, events} -> events
            _ -> []
          end

        # Inject NIP-29 metadata events if requested
        nip29_events =
          case filter_map["kinds"] do
            nil -> GcIndexRelay.NIP29.Core.synthesize_metadata_events([39000, 39001, 39002])
            kinds when is_list(kinds) ->
              nip29_kinds = Enum.filter(kinds, & &1 in [39000, 39001, 39002])
              if nip29_kinds != [] do
                GcIndexRelay.NIP29.Core.synthesize_metadata_events(nip29_kinds)
              else
                []
              end
            _ -> []
          end

        # Note: In a real implementation we would filter `nip29_events` by other filter
        # parameters (authors, ids, tags) if they are present, but usually clients query
        # `39000` with just the kind or kind+author.
        
        Enum.map(db_events ++ nip29_events, fn e ->
          {:text, Jason.encode!(["EVENT", sub_id, e])}
        end)
      end)

    eose = {:text, Jason.encode!(["EOSE", sub_id])}

    {:push, history_replies ++ [eose], state}
  end

  defp handle_event(event_map, state) do
    pub_event_keys = ~w(id pubkey created_at kind tags content sig)
    
    pub_event =
      pub_event_keys
      |> Enum.reduce(%{}, fn key, acc ->
        case Map.get(event_map, key) do
          nil -> acc
          v -> Map.put(acc, String.to_existing_atom(key), v)
        end
      end)
      |> Map.put_new(:tags, [])
      |> Map.put_new(:content, "")
      |> then(&struct(PubEvent, &1))

    case Nostr.create_event(pub_event) do
      {:ok, _event} ->
        {:push, [{:text, Jason.encode!(["OK", pub_event.id, true, ""])}], state}

      {:error, reason} ->
        # Ecto changeset errors might not easily to_string, but string errors will
        msg = if is_binary(reason), do: reason, else: inspect(reason)
        {:push, [{:text, Jason.encode!(["OK", pub_event.id, false, msg])}], state}
    end
  end

  defp handle_close(sub_id, state) do
    state = update_in(state.subs, &Map.delete(&1, sub_id))

    if map_size(state.subs) == 0 do
      Phoenix.PubSub.unsubscribe(GcIndexRelay.PubSub, "events")
    end

    {:ok, state}
  end

  @impl true
  def handle_info({:new_event, event}, state) do
    replies =
      state.subs
      |> Enum.flat_map(fn {sub_id, filters} ->
        if event_matches_any?(event, filters) do
          [{:text, Jason.encode!(["EVENT", sub_id, event])}]
        else
          []
        end
      end)

    if replies == [] do
      {:ok, state}
    else
      {:push, replies, state}
    end
  end

  defp event_matches_any?(_event, []), do: false

  defp event_matches_any?(event, filters) do
    Enum.any?(filters, fn filter ->
      matches_kind?(event, filter) &&
        matches_authors?(event, filter) &&
        matches_ids?(event, filter) &&
        matches_tags?(event, filter)
    end)
  end

  defp matches_kind?(event, filter) do
    is_nil(filter.kinds) or event.kind in filter.kinds
  end

  defp matches_authors?(event, filter) do
    is_nil(filter.authors) or event.pubkey in filter.authors
  end

  defp matches_ids?(event, filter) do
    is_nil(filter.ids) or event.id in filter.ids
  end

  defp matches_tags?(event, filter) do
    is_nil(filter.tags) or Enum.all?(filter.tags, fn {tag_name, valid_values} ->
      Enum.any?(event.tags || [], fn
        [^tag_name, value | _] -> value in valid_values
        _ -> false
      end)
    end)
  end
end
