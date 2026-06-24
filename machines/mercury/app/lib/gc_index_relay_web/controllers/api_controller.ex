defmodule GcIndexRelayWeb.ApiController do
  use GcIndexRelayWeb, :controller

  def index(conn, _params) do
    relay_info = Application.fetch_env!(:gc_index_relay, :relay_info)

    json(conn, %{
      relay: Keyword.fetch!(relay_info, :name),
      version:
        Keyword.get(relay_info, :version, Application.spec(:gc_index_relay, :vsn)) |> to_string(),
      endpoints: [
        %{
          method: "GET",
          path: "/api/events",
          description: "List events (requires filter params)"
        },
        %{
          method: "POST",
          path: "/api/events/filter",
          description: "Query events with a NIP-01 filter body"
        },
        %{
          method: "POST",
          path: "/api/publications/search",
          description: "Exact metadata search for kind-30040 publication indexes"
        },
        %{method: "GET", path: "/api/events/:id", description: "Get a single event by ID"},
        %{method: "POST", path: "/api/events", description: "Publish a new event"},
        %{method: "DELETE", path: "/api/events/:id", description: "Delete an event by ID"},
        %{method: "GET", path: "/api/swagger", description: "Swagger UI"},
        %{method: "GET", path: "/health", description: "Health check"}
      ]
    })
  end
end
