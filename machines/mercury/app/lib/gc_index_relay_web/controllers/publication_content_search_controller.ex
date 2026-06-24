defmodule GcIndexRelayWeb.PublicationContentSearchController do
  use GcIndexRelayWeb, :controller
  use PhoenixSwagger

  alias GcIndexRelay.Nostr.PublicationContentSearch

  action_fallback GcIndexRelayWeb.FallbackController

  swagger_path :search do
    post("/api/publications/content/search")
    summary("Search kind-30041 publication section body text")

    description("""
    Full-text search over publication section `content` (kind 30041). Case-insensitive phrase
    matching; quoted queries require a contiguous phrase; unquoted multi-word queries also match
    when all significant words appear anywhere in the section body.
    """)

    tag("Publications")
    operation_id("search_publication_content")
    response(200, "OK", Schema.ref(:PubEventList))
    response(400, "Bad Request")
  end

  @doc """
  POST /api/publications/content/search — body search for kind-30041 publication sections.
  """
  def search(conn, params) do
    with {:ok, query} <- fetch_query(params),
         {:ok, limit} <- parse_limit(Map.get(params, "limit", 25)),
         :ok <- validate_limit(limit),
         {:ok, events} <- PublicationContentSearch.search(query, limit: limit) do
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
