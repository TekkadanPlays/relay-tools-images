defmodule GcIndexRelay.Nostr do
  @moduledoc """
  The Nostr context.

  ## Supported Operations

  The Nostr context module supports create, read, and delete operations on events, as well as a
  number of query types to find collections of events. Update operations are not supported, since a
  Nostr event, once signed, is immutable.
  """

  import Ecto.Query, warn: false
  alias GcIndexRelay.Nostr.Validator
  alias GcIndexRelay.Nostr.Moderation
  alias GcIndexRelay.Nostr.PubEvent
  alias GcIndexRelay.Nostr.Filter
  alias GcIndexRelay.Repo
  alias GcIndexRelay.Nostr.Event

  @doc """
  Gets a single Nostr event from the database.

  Returns: `GcIndexRelay.Nostr.PubEvent`
  """
  @spec get_event(binary()) :: {:ok, PubEvent.t()} | {:error, :not_found}
  def get_event(id) when is_binary(id) do
    with {:ok, binary_id} <- Base.decode16(id, case: :lower),
         %Event{} = event <- Repo.get(Event, binary_id),
         event_with_tags <- Repo.preload(event, :tags) do
      PubEvent.from_db(event_with_tags)
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Queries Nostr events using a NIP-01 filter.

  Returns a list of `GcIndexRelay.Nostr.PubEvent` structs matching the filter criteria.
  """
  @spec query_events(map()) :: {:ok, [PubEvent.t()]} | {:error, String.t()}
  def query_events(filter_map) when is_map(filter_map) do
    with {:ok, filter} <- Filter.from_map(filter_map),
         events <-
           from(e in Event)
           |> Filter.apply(filter) do
      pub_events_from_db(events)
    end
  end

  defp pub_events_from_db(events) do
    Enum.reduce_while(events, {:ok, []}, fn event, {:ok, acc} ->
      case PubEvent.from_db(event) do
        {:ok, pub_event} -> {:cont, {:ok, [pub_event | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Writes a `GcIndexRelay.Nostr.PubEvent` to the database (if not ephemeral).
  Broadcasts the event via PubSub.
  """
  def create_event(event) when is_struct(event, PubEvent) do
    with {:ok, event} <- Validator.validate_id(event),
         {:ok, event} <- Validator.validate_signature(event),
         {:ok, event} <- Validator.validate_not_protected(event),
         {:ok, event} <- validate_not_banned(event),
         {:ok, event} <- Moderation.validate_community_access(event),
         {:ok, event} <- GcIndexRelay.NIP29.Validation.validate_permissions(event) do
      
      if event.kind == 5 do
        process_deletions(event)
      end

      result =
        if ephemeral?(event.kind) do
          # Ephemeral events are not stored in the DB
          {:ok, event}
        else
          case PubEvent.to_db(event) do
            {:ok, db_event} ->
              tags_as_maps = Enum.map(db_event.tags, &Map.from_struct/1)
              attrs = db_event |> Map.from_struct() |> Map.put(:tags, tags_as_maps)

              %Event{}
              |> Event.changeset(attrs)
              |> Repo.insert()
              |> case do
                {:ok, _} -> {:ok, event}
                {:error, _} = err -> err
              end

            {:error, _} = err ->
              err
          end
        end

      if match?({:ok, _}, result) do
        Phoenix.PubSub.broadcast(GcIndexRelay.PubSub, "events", {:new_event, event})
      end

      result
    end
  end

  defp validate_not_banned(event) when is_struct(event, PubEvent) do
    alias GcIndexRelay.Auth.Roles

    # Extract community scope from the event's "a" tag (if present)
    community_scope =
      (event.tags || [])
      |> Enum.find_value(fn
        ["a", value | _] ->
          case String.split(value, ":", parts: 3) do
            ["34550", _pubkey, _name] -> value
            _ -> nil
          end
        _ -> nil
      end)

    cond do
      Roles.is_banned?(event.pubkey) ->
        {:error, "blocked: user is banned from this relay"}
      community_scope != nil and Roles.is_banned?(event.pubkey, community_scope) ->
        {:error, "blocked: user is banned from this community"}
      true ->
        {:ok, event}
    end
  end

  defp ephemeral?(kind), do: kind >= 20000 and kind < 30000

  defp process_deletions(deletion_event) do
    target_ids =
      (deletion_event.tags || [])
      |> Enum.filter(fn [name | _] -> name == "e" end)
      |> Enum.map(fn [_, value | _] -> value end)

    for target_id <- target_ids do
      case get_event(target_id) do
        {:ok, target_event} ->
          if deletion_event.pubkey == target_event.pubkey or
               Moderation.authorize_admin_deletion?(deletion_event, target_event) do
            delete_event(target_event)
          end
        _ -> :ok
      end
    end
  end

  @doc """
  Deletes a `GcIndexRelay.Nostr.PubEvent` from the database.
  """
  @spec delete_event(PubEvent.t()) :: {:ok, Ecto.Schema.t()} | {:error, Ecto.Changeset.t()}
  def delete_event(event) when is_struct(event, PubEvent) do
    case Base.decode16(event.id, case: :lower) do
      {:ok, binary_id} ->
        Repo.delete(%Event{id: binary_id})

      _ ->
        {:error, :not_found}
    end
  end
end
