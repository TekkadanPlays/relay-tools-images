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
        json(conn, Enum.map(events, fn e ->
          %{
            id: e.id,
            pubkey: e.pubkey,
            created_at: e.created_at,
            kind: e.kind,
            content: e.content,
            sig: e.sig,
            tags: e.tags
          }
        end))
        
      {:error, _reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to fetch communities"})
    end
  end
end

