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
  Synthesizes a list of kind 39000 events for all known groups.
  """
  def synthesize_discovery_events() do
    privkey_hex = Application.get_env(:gc_index_relay, :relay_privkey)
    pubkey_hex = Application.get_env(:gc_index_relay, :relay_pubkey)

    if is_nil(privkey_hex) or is_nil(pubkey_hex) or privkey_hex == "" do
      []
    else
      privkey_hex = String.trim(privkey_hex) |> String.downcase()
      pubkey_hex = String.trim(pubkey_hex) |> String.downcase()
      
      get_active_group_ids()
      |> Enum.map(&synthesize_group_event(&1, privkey_hex, pubkey_hex))
      |> Enum.reject(&is_nil/1)
    end
  end

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

  defp synthesize_group_event(group_id, privkey_hex, pubkey_hex) do
    # Fetch the latest 9002 metadata event to extract group attributes
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
          |> Enum.map(fn tag -> [tag.name, tag.value] ++ (tag.extra || []) end)
        nil ->
          []
      end

    tags = [["d", group_id]] ++ metadata_tags

    with {:ok, privkey_bin} <- Base.decode16(privkey_hex, case: :lower) do
      event = %PubEvent{
        pubkey: pubkey_hex,
        created_at: System.system_time(:second),
        kind: 39000,
        tags: tags,
        content: ""
      }
      
      # NIP-01 ID generation: sha256([0, pubkey, created_at, kind, tags, content])
      id_json = Jason.encode!([0, event.pubkey, event.created_at, event.kind, event.tags, event.content])
      id_hex = :crypto.hash(:sha256, id_json) |> Base.encode16(case: :lower)
      event = %{event | id: id_hex}
      
      id_bin = Base.decode16!(id_hex, case: :lower)
      
      # Sign with schnorr
      try do
        sig_bin = Secp256k1.schnorr_sign(id_bin, privkey_bin)
        %{event | sig: Base.encode16(sig_bin, case: :lower)}
      rescue
        e -> 
          Logger.error("Failed to sign NIP-29 event for group #{group_id}: #{inspect(e)}")
          nil
      end
    else
      _ -> 
        Logger.error("Invalid MERCURY_RELAY_PRIVKEY hex format")
        nil
    end
  end
end
