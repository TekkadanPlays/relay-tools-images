defmodule GcIndexRelayWeb.SettingsController do
  use GcIndexRelayWeb, :controller

  alias GcIndexRelay.Nostr
  alias GcIndexRelay.Nostr.PubEvent

  @doc """
  GET /api/settings/:pubkey
  Fetches the most recent kind 30078 (app settings) event for the given pubkey.
  """
  def show(conn, %{"pubkey" => pubkey}) do
    filter = %{
      "kinds" => [30078],
      "authors" => [pubkey],
      "limit" => 1
    }
    
    case Nostr.query_events(filter) do
      {:ok, [event | _]} ->
        conn
        |> put_view(GcIndexRelayWeb.EventView)
        |> render("show.json", event: event)
        
      {:ok, []} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "No settings found for this pubkey"})
        
      {:error, _reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to fetch settings"})
    end
  end

  @pub_event_keys ~w(id pubkey created_at kind tags content sig)

  @doc """
  POST /api/settings/:pubkey
  Accepts a Nostr event (kind 30078) and stores it on the instance.
  Enforces that the event's pubkey matches the URL pubkey.
  """
  def update(conn, %{"pubkey" => pubkey} = params) do
    # In case the client sends {"event": {...}} or just the raw event
    event_params = Map.get(params, "event", params)

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

    if pub_event.pubkey == pubkey and pub_event.kind == 30078 do
      # The Nostr insert pipeline automatically verifies the BIP-340 signature.
      case Nostr.create_event(pub_event) do
        {:ok, _} ->
          conn
          |> put_status(:ok)
          |> json(%{success: true, id: pub_event.id})
          
        {:error, reason} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "Failed to save settings: #{inspect(reason)}"})
      end
    else
      conn
      |> put_status(:bad_request)
      |> json(%{error: "Event must be kind 30078 and match the URL pubkey"})
    end
  end
end
