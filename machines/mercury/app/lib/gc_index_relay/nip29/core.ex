defmodule GcIndexRelay.NIP29.Core do
  @moduledoc """
  Core logic for NIP-29 (Relay-based Groups).
  """
  import Ecto.Query
  alias GcIndexRelay.Repo
  alias GcIndexRelay.Nostr.Event
  alias GcIndexRelay.Nostr.PubEvent
  require Logger

  @doc """
  Synthesizes a list of NIP-29 metadata events for all known groups.
  """
  def synthesize_metadata_events(kinds) when is_list(kinds) do
    privkey_hex = Application.get_env(:gc_index_relay, :relay_privkey)
    pubkey_hex = Application.get_env(:gc_index_relay, :relay_pubkey)

    if is_nil(privkey_hex) or is_nil(pubkey_hex) or privkey_hex == "" do
      []
    else
      privkey_hex = String.trim(privkey_hex) |> String.downcase()
      pubkey_hex = String.trim(pubkey_hex) |> String.downcase()
      
      with {:ok, privkey_bin} <- Base.decode16(privkey_hex, case: :lower) do
        get_active_group_ids()
        |> Enum.flat_map(fn group_id ->
          synthesize_group_events(group_id, kinds, privkey_bin, pubkey_hex)
        end)
        |> Enum.reject(&is_nil/1)
      else
        _ -> 
          Logger.error("Invalid MERCURY_RELAY_PRIVKEY hex format")
          []
      end
    end
  end
  def synthesize_metadata_events(_), do: []

  defp get_active_group_ids() do
    # Any group that has had a 9007 (create) event or 9002 (metadata) event is considered active
    query = 
      from e in Event,
      join: t in assoc(e, :tags),
      where: e.kind in [9002, 9007] and t.name == "h",
      select: t.value,
      distinct: true

    Repo.all(query)
  end

  defp synthesize_group_events(group_id, kinds, privkey_bin, pubkey_hex) do
    admins = if Enum.any?(kinds, & &1 in [39001, 39002]), do: get_group_admins(group_id), else: []
    members = if 39002 in kinds, do: get_group_members(group_id, admins), else: []

    Enum.map(kinds, fn
      39000 -> synthesize_39000(group_id, privkey_bin, pubkey_hex)
      39001 -> synthesize_39001(group_id, admins, privkey_bin, pubkey_hex)
      39002 -> synthesize_39002(group_id, members, privkey_bin, pubkey_hex)
      _ -> nil
    end)
  end

  defp synthesize_39000(group_id, privkey_bin, pubkey_hex) do
    query = 
      from e in Event,
      join: t in assoc(e, :tags),
      where: e.kind == 9002 and t.name == "h" and t.value == ^group_id,
      order_by: [desc: e.created_at],
      preload: [:tags],
      limit: 1

    metadata_tags = 
      case Repo.one(query) do
        %Event{} = metadata_event ->
          metadata_event.tags
          |> Enum.reject(fn tag -> tag.name == "h" end)
          |> Enum.map(fn tag ->
            additional = tag.additional_values || []
            case tag.value do
              nil -> [tag.name]
              v -> [tag.name, v | additional]
            end
          end)
        nil ->
          []
      end

    tags = [["d", group_id]] ++ metadata_tags
    sign_and_build_event(39000, tags, privkey_bin, pubkey_hex)
  end

  defp synthesize_39001(group_id, admins, privkey_bin, pubkey_hex) do
    tags = [["d", group_id]] ++ Enum.map(admins, fn pubkey -> ["p", pubkey, "admin"] end)
    sign_and_build_event(39001, tags, privkey_bin, pubkey_hex)
  end

  defp synthesize_39002(group_id, members, privkey_bin, pubkey_hex) do
    tags = [["d", group_id]] ++ Enum.map(members, fn pubkey -> ["p", pubkey] end)
    sign_and_build_event(39002, tags, privkey_bin, pubkey_hex)
  end

  defp get_group_admins(group_id) do
    creator_query = 
      from e in Event,
      join: t in assoc(e, :tags),
      where: e.kind == 9007 and t.name == "h" and t.value == ^group_id,
      select: e.pubkey,
      limit: 1

    creator_hex = 
      case Repo.one(creator_query) do
        nil -> nil
        bin -> Base.encode16(bin, case: :lower)
      end

    role_query = 
      from e in Event,
      join: t in assoc(e, :tags),
      join: p in assoc(e, :tags),
      where: e.kind in [9003, 9004] and t.name == "h" and t.value == ^group_id,
      where: p.name == "p",
      order_by: [desc: e.created_at],
      select: %{kind: e.kind, target: p.value}

    granted_admins = 
      Repo.all(role_query)
      |> Enum.reduce(%{}, fn event, acc ->
        Map.put_new(acc, event.target, event.kind)
      end)
      |> Enum.filter(fn {_target, kind} -> kind == 9003 end)
      |> Enum.map(fn {target, _} -> target end)

    ([creator_hex] ++ granted_admins)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp get_group_members(group_id, admins) do
    member_query = 
      from e in Event,
      join: t in assoc(e, :tags),
      join: p in assoc(e, :tags),
      where: e.kind in [9000, 9001] and t.name == "h" and t.value == ^group_id,
      where: p.name == "p",
      order_by: [desc: e.created_at],
      select: %{kind: e.kind, target: p.value}

    granted_members = 
      Repo.all(member_query)
      |> Enum.reduce(%{}, fn event, acc ->
        Map.put_new(acc, event.target, event.kind)
      end)
      |> Enum.filter(fn {_target, kind} -> kind == 9000 end)
      |> Enum.map(fn {target, _} -> target end)

    (admins ++ granted_members)
    |> Enum.uniq()
  end

  def auto_approve_join_request(join_event) do
    # Extract group_id
    group_id = Enum.find_value(join_event.tags || [], fn
      ["h", gid | _] -> gid
      _ -> nil
    end)

    if group_id do
      privkey_hex = Application.get_env(:gc_index_relay, :relay_privkey)
      pubkey_hex = Application.get_env(:gc_index_relay, :relay_pubkey)

      if not is_nil(privkey_hex) and not is_nil(pubkey_hex) and privkey_hex != "" do
        privkey_hex = String.trim(privkey_hex) |> String.downcase()
        pubkey_hex = String.trim(pubkey_hex) |> String.downcase()
        
        with {:ok, privkey_bin} <- Base.decode16(privkey_hex, case: :lower) do
          # Synthesize a 9000 event adding the user
          tags = [["h", group_id], ["p", join_event.pubkey]]
          
          case sign_and_build_event(9000, tags, privkey_bin, pubkey_hex) do
            %PubEvent{} = add_event ->
              # Save it to the database
              case PubEvent.to_db(add_event) do
                {:ok, db_event} ->
                  tags_as_maps = Enum.map(db_event.tags, &Map.from_struct/1)
                  attrs = db_event |> Map.from_struct() |> Map.put(:tags, tags_as_maps)

                  case Repo.insert(Event.changeset(%Event{}, attrs)) do
                    {:ok, _} ->
                      # Broadcast the event
                      Phoenix.PubSub.broadcast(GcIndexRelay.PubSub, "events", {:new_event, add_event})
                      Logger.info("Auto-approved join request for pubkey #{join_event.pubkey} in group #{group_id}")
                    _ ->
                      Logger.error("Failed to insert auto-generated 9000 event")
                  end
                _ -> :ok
              end
            _ -> :ok
          end
        end
      end
    end
  end

  defp sign_and_build_event(kind, tags, privkey_bin, pubkey_hex) do
    event = %PubEvent{
      pubkey: pubkey_hex,
      created_at: System.system_time(:second),
      kind: kind,
      tags: tags,
      content: ""
    }
    
    id_json = Jason.encode!([0, event.pubkey, event.created_at, event.kind, event.tags, event.content])
    id_hex = :crypto.hash(:sha256, id_json) |> Base.encode16(case: :lower)
    event = %{event | id: id_hex}
    
    id_bin = Base.decode16!(id_hex, case: :lower)
    
    try do
      sig_bin = Secp256k1.schnorr_sign(id_bin, privkey_bin)
      %{event | sig: Base.encode16(sig_bin, case: :lower)}
    rescue
      e -> 
        Logger.error("Failed to sign NIP-29 event kind #{kind}: #{inspect(e)}")
        nil
    end
  end
end
