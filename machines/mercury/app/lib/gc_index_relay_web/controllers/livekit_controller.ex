defmodule GcIndexRelayWeb.LiveKitController do
  use GcIndexRelayWeb, :controller
  alias GcIndexRelay.NIP29.Validation

  @doc """
  Generates a LiveKit token for joining a NIP-29 Group Voice room.
  Requires a valid NIP-98 Authorization header.
  """
  def get_token(conn, %{"group_id" => group_id}) do
    pubkey = conn.assigns[:pubkey]

    if is_nil(pubkey) do
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "Missing or invalid NIP-98 authorization"})
    else
      # Check if the user is a member of the group
      if Validation.is_member?(group_id, pubkey) do
        mint_and_send_token(conn, group_id, pubkey)
      else
        conn
        |> put_status(:forbidden)
        |> json(%{error: "User is not a member of this group"})
      end
    end
  end

  def get_dm_token(conn, %{"room_id" => room_id}) do
    pubkey = conn.assigns[:pubkey]

    if is_nil(pubkey) do
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "Missing or invalid NIP-98 authorization"})
    else
      # For DM rooms (e.g. dm:pubkey1:pubkey2), verify the pubkey is in the room ID
      if String.starts_with?(room_id, "dm:") and String.contains?(room_id, pubkey) do
        mint_and_send_token(conn, room_id, pubkey)
      else
        conn
        |> put_status(:forbidden)
        |> json(%{error: "User is not a participant of this DM room"})
      end
    end
  end

  defp mint_and_send_token(conn, room, pubkey) do
    api_key = Application.get_env(:gc_index_relay, :livekit_api_key)
    api_secret = Application.get_env(:gc_index_relay, :livekit_api_secret)
    url = Application.get_env(:gc_index_relay, :livekit_url)

    if is_nil(api_key) or is_nil(api_secret) or is_nil(url) do
      conn
      |> put_status(:service_unavailable)
      |> json(%{error: "LiveKit integration is not configured on this relay"})
    else
      now = System.system_time(:second)
      exp = now + (6 * 60 * 60) # 6 hours

      # Randomize identity to avoid LiveKit evicting active sessions if joined from multiple tabs
      identity = "#{pubkey}-#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}"

      claims = %{
        "iss" => api_key,
        "nbf" => now - 5,
        "exp" => exp,
        "sub" => identity,
        "video" => %{
          "room" => room,
          "roomJoin" => true,
          "canPublish" => true,
          "canSubscribe" => true
        }
      }

      signer = Joken.Signer.create("HS256", api_secret)

      case Joken.generate_and_sign(%{}, claims, signer) do
        {:ok, token} ->
          conn
          |> put_status(:ok)
          |> json(%{
            participant_token: token,
            server_url: url
          })
        {:error, _reason} ->
          conn
          |> put_status(:internal_server_error)
          |> json(%{error: "Failed to generate LiveKit token"})
      end
    end
  end
end
