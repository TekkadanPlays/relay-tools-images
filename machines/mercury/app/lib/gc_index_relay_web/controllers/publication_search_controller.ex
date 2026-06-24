defmodule GcIndexRelayWeb.PublicationSearchController do
  use GcIndexRelayWeb, :controller
  use PhoenixSwagger

  alias GcIndexRelay.Nostr.PublicationSearch

  action_fallback GcIndexRelayWeb.FallbackController

  swagger_path :search do
    post("/api/publications/search")
    summary("Search kind-30040 publication indexes by metadata")

    description("""
    Metadata search over publication index tags: `d`, `title`, `author`, and `source`.
    Matching is case-insensitive, treats hyphens and spaces as equivalent, supports substring
    matches (needle length ≥ 2), hyphen-segment matches on `d` tags, and multi-word AND queries.
    """)

    tag("Publications")
    operation_id("search_publications")
    response(200, "OK", Schema.ref(:PubEventList))
    response(400, "Bad Request")
  end

  @doc """
  POST /api/publications/search — metadata search for kind-30040 publication indexes.
  """
  def search(conn, params) do
    with {:ok, query} <- fetch_query(params),
         {:ok, limit} <- parse_limit(Map.get(params, "limit", 25)),
         :ok <- validate_limit(limit),
         {:ok, events} <- PublicationSearch.search(query, limit: limit) do
      render(conn, :index, events: events)
    end
  end

  defp fetch_query(%{"q" => q}) when is_binary(q) do
    trimmed = String.trim(q)
    if trimmed == "", do: {:error, "Query q must not be empty."}, else: {:ok, trimmed}
  end

  defp fetch_query(_), do: {:error, "Missing required field: q"}

  defp parse_limit(v) when is_integer(v), do: {:ok, v}

  defp parse_limit(v) when is_binary(v) do
    case Integer.parse(v) do
      {int, ""} -> {:ok, int}
      _ -> {:error, "Invalid limit: must be an integer between 1 and 100"}
    end
  end

  defp parse_limit(_), do: {:error, "Invalid limit: must be an integer between 1 and 100"}

  defp validate_limit(limit) when is_integer(limit) and limit >= 1 and limit <= 100, do: :ok
  defp validate_limit(_), do: {:error, "The limit must be between 1 and 100."}
end
