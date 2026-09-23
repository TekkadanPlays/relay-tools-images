defmodule GcIndexRelayWeb.CommunityDiscoveryController do
  use GcIndexRelayWeb, :controller

  alias GcIndexRelay.Nostr

  @doc """
  GET /api/communities - Returns a list of communities (kind 34550) known to this instance.
  """
  def index(conn, _params) do
    # Find all kind 34550 events in the database
    filter = %{
      "kinds" => [34550],
      "limit" => 100
    }
    
    case Nostr.query_events(filter) do
      {:ok, events} ->
        # Render using the existing EventView
        conn
        |> put_view(GcIndexRelayWeb.EventView)
        |> render("index.json", events: events)
        
      {:error, _reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to fetch communities"})
    end
  end
end
