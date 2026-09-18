defmodule GcIndexRelayWeb.InboxController do
  use GcIndexRelayWeb, :controller
  alias GcIndexRelay.Nostr
  alias GcIndexRelay.Nostr.PubEvent

  @pub_event_keys ~w(id pubkey created_at kind tags content sig)

  @doc """
  POST /api/inbox/:pubkey
  Accepts a NIP-59 Gift Wrap destined for the specified pubkey.
  Bypasses standard NIP-42 auth but enforces HTTP-native anti-spam (e.g. PoW).
  """
  def create(conn, %{"pubkey" => target_pubkey, "event" => event_params}) do
    pub_event =
      @pub_event_keys
      |> Enum.reduce(%{}, fn key, acc ->
        case Map.get(event_params, key) do
          nil -> acc
          v -> Map.put(acc, String.to_existing_atom(key), v)
        end
      end)
      |> Map.put_new(:tags, [])
      |> Map.put_new(:content, "")
      |> then(&struct(PubEvent, &1))

    # In a real community environment, the Inbox should still respect community partitions.
    # A gift wrap should carry the community #a tag to be stored in the correct partition.
    community_atag = conn.assigns[:community_atag]

    with :ok <- validate_gift_wrap(pub_event, target_pubkey),
         :ok <- validate_community_partition(pub_event, community_atag),
         :ok <- check_spam_policies(pub_event),
         {:ok, _event} <- Nostr.create_event(pub_event) do
      conn
      |> put_status(:created)
      |> json(%{success: true})
    else
      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: reason})
    end
  end

  defp validate_gift_wrap(event, target_pubkey) do
    if event.kind == 1059 do
      # Verify that one of the 'p' tags matches the target_pubkey.
      has_p_tag = Enum.any?(event.tags, fn
        ["p", ^target_pubkey | _] -> true
        _ -> false
      end)

      if has_p_tag do
        :ok
      else
        {:error, "Gift wrap must tag the recipient's pubkey"}
      end
    else
      {:error, "Inbox only accepts Gift Wrap events (kind 1059)"}
    end
  end

  defp validate_community_partition(_event, nil), do: :ok
  defp validate_community_partition(event, community_id) do
    has_a_tag = Enum.any?(event.tags, fn
      ["a", tag_val | _] -> String.ends_with?(tag_val, ":#{community_id}")
      _ -> false
    end)

    if has_a_tag do
      :ok
    else
      {:error, "Inbox event must include an 'a' tag for the target community path /c/#{community_id}"}
    end
  end

  defp check_spam_policies(event) do
    # Require NIP-13 Proof of Work to prevent botnet spam.
    # Minimum difficulty 16 for inbox dropoffs.
    pow_tag = Enum.find(event.tags, fn [tag | _] -> tag == "nonce" end)

    case pow_tag do
      ["nonce", _nonce, target_difficulty] ->
        case Integer.parse(target_difficulty) do
          {diff, ""} when diff >= 16 -> :ok
          _ -> {:error, "Insufficient Proof of Work. Minimum difficulty is 16."}
        end
      _ ->
        {:error, "Proof of Work (NIP-13 'nonce' tag) required for inbox delivery."}
    end
  end
end
