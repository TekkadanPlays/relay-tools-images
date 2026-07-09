defmodule GcIndexRelay.NIP29.Validation do
  @moduledoc """
  Validates NIP-29 Group Management events and enforces write permissions.
  """
  import Ecto.Query
  alias GcIndexRelay.Repo
  alias GcIndexRelay.Nostr.Event

  def validate_permissions(event) do
    case extract_group_id(event) do
      nil -> 
        # Not a group event, allow
        {:ok, event}
      group_id ->
        cond do
          event.kind == 9007 -> 
            # Anyone can create a group
            {:ok, event}
          
          event.kind == 9021 ->
            # Join request
            tags = get_group_metadata(group_id)
            if "closed" in tags do
              {:error, "forbidden: group #{group_id} is closed"}
            else
              {:ok, event}
            end

          event.kind == 9022 ->
            # Leave request
            {:ok, event}

          event.kind >= 9000 and event.kind <= 9020 ->
            # Management events require admin rights
            if is_admin?(group_id, event.pubkey) do
              {:ok, event}
            else
              {:error, "forbidden: user is not an admin of group #{group_id}"}
            end
            
          true ->
            # Regular events (kind 9, 11, etc)
            tags = get_group_metadata(group_id)
            if "restricted" in tags do
              if is_member?(group_id, event.pubkey) do
                {:ok, event}
              else
                {:error, "forbidden: user is not a member of restricted group #{group_id}"}
              end
            else
              # Open groups allow anyone to write
              {:ok, event}
            end
        end
    end
  end

  defp extract_group_id(event) do
    Enum.find_value(event.tags || [], fn
      ["h", group_id | _] -> group_id
      _ -> nil
    end)
  end

  defp get_group_metadata(group_id) do
    query = 
      from e in Event,
      join: t in assoc(e, :tags),
      where: e.kind == 9002 and t.name == "h" and t.value == ^group_id,
      order_by: [desc: e.created_at],
      preload: [:tags],
      limit: 1

    case Repo.one(query) do
      %Event{} = metadata_event ->
        metadata_event.tags |> Enum.map(& &1.name)
      nil ->
        []
    end
  end

  def is_admin?(group_id, pubkey) do
    case Base.decode16(pubkey, case: :lower) do
      {:ok, pubkey_bin} ->
        creator_query = 
          from e in Event,
          join: t in assoc(e, :tags),
          where: e.kind == 9007 and t.name == "h" and t.value == ^group_id,
          where: e.pubkey == ^pubkey_bin,
          select: e.id,
          limit: 1

        if Repo.one(creator_query) != nil do
          true
        else
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
      _ ->
        false
    end
  end

  def is_member?(group_id, pubkey) do
    if is_admin?(group_id, pubkey) do
      true
    else
      member_query = 
        from e in Event,
        join: t in assoc(e, :tags),
        join: p in assoc(e, :tags),
        where: e.kind in [9000, 9001] and t.name == "h" and t.value == ^group_id,
        where: p.name == "p" and p.value == ^pubkey,
        order_by: [desc: e.created_at],
        limit: 1

      case Repo.one(member_query) do
        %Event{kind: 9000} -> true
        _ -> false
      end
    end
  end
end
