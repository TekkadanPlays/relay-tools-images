defmodule GcIndexRelay.Nostr.Moderation do
  @moduledoc """
  Handles community-based moderation rules, such as community bans and admin deletion capabilities.
  """

  alias GcIndexRelay.Nostr.PubEvent
  alias GcIndexRelay.Nostr.Event
  alias GcIndexRelay.Repo
  import Ecto.Query

  @doc """
  Inspects incoming events for a community `a` tag (e.g. 34550:...).
  If present, checks the community admin's mute list (kind 30000).
  Rejects the event if the author is on the mute list.
  """
  def validate_community_access(event) when is_struct(event, PubEvent) do
    case extract_community_tag(event) do
      nil ->
        {:ok, event}

      {admin_pubkey, _community_name} ->
        if user_banned?(admin_pubkey, event.pubkey) do
          {:error, "blocked: user is banned from this community"}
        else
          {:ok, event}
        end
    end
  end

  @doc """
  Checks if a deletion request (kind 5) is authorized by a community admin.
  If the target event is in a community, and the deletion is signed by the admin, returns true.
  """
  def authorize_admin_deletion?(deletion_event, target_event) do
    case extract_community_tag(target_event) do
      nil -> false
      {admin_pubkey, _} -> deletion_event.pubkey == admin_pubkey
    end
  end

  defp extract_community_tag(event) do
    Enum.find_value(event.tags || [], fn
      ["a", value | _rest] ->
        case String.split(value, ":", parts: 3) do
          ["34550", admin_pubkey, community_name] -> {admin_pubkey, community_name}
          _ -> nil
        end
      _ ->
        nil
    end)
  end

  defp user_banned?(admin_pubkey, author_pubkey) do
    with {:ok, binary_admin} <- Base.decode16(admin_pubkey, case: :lower) do
      query = 
        from e in Event,
        join: t in assoc(e, :tags),
        where: e.kind == 30000 and e.pubkey == ^binary_admin,
        where: t.name == "p" and t.value == ^author_pubkey,
        select: e.id,
        limit: 1

      Repo.one(query) != nil
    else
      _ -> false
    end
  end
end
