defmodule GcIndexRelay.NIP29.Validation do
  @moduledoc """
  Validates NIP-29 Group Management events (9000-9021).
  """
  import Ecto.Query
  alias GcIndexRelay.Repo
  alias GcIndexRelay.Nostr.Event
  alias GcIndexRelay.Nostr.PubEvent

  def validate_permissions(event) when event.kind >= 9000 and event.kind <= 9021 do
    cond do
      event.kind == 9007 -> 
        # Anyone can create a group
        {:ok, event}
      
      true ->
        # Other management events require admin rights
        case extract_group_id(event) do
          nil -> 
            {:error, "invalid NIP-29 event: missing 'h' tag"}
          group_id ->
            if is_admin?(group_id, event.pubkey) do
              {:ok, event}
            else
              {:error, "forbidden: user is not an admin of group #{group_id}"}
            end
        end
    end
  end
  def validate_permissions(event), do: {:ok, event}

  defp extract_group_id(event) do
    Enum.find_value(event.tags || [], fn
      ["h", group_id | _] -> group_id
      _ -> nil
    end)
  end

  defp is_admin?(group_id, pubkey) do
    creator_query = 
      from e in Event,
      join: t in assoc(e, :tags),
      where: e.kind == 9007 and t.name == "h" and t.value == ^group_id,
      where: e.pubkey == ^pubkey,
      select: e.id,
      limit: 1

    if Repo.one(creator_query) != nil do
      true
    else
      # Check if granted admin via 9003 and not removed by 9004
      role_query = 
        from e in Event,
        join: t in assoc(e, :tags),
        join: p in assoc(e, :tags),
        where: e.kind in [9003, 9004] and t.name == "h" and t.value == ^group_id,
        where: p.name == "p" and p.value == ^pubkey,
        order_by: [desc: e.created_at],
        limit: 1

      case Repo.one(role_query) do
        %Event{kind: 9003} -> true
        _ -> false
      end
    end
  end
end
