defmodule GcIndexRelayWeb.FilterController do
  use GcIndexRelayWeb, :controller
  use PhoenixSwagger

  alias GcIndexRelay.Nostr

  action_fallback GcIndexRelayWeb.FallbackController

  swagger_path :index do
    get("/api/events")
    summary("Query events by specifying NIP-01 filter parameters in the URL query string.")

    description("""
    The `since`, `until`, and `limit` parameters are required. This ensures every query generates a
    unique, repeatable response. Queries that do not specify `since`, `until`, or `limit` should be
    made against POST /api/events/filter.
    """)

    tag("Events")
    operation_id("query_events")

    parameters do
      since(:query, :integer, "Start time", required: true)
      until(:query, :integer, "End time", required: true)
      limit(:query, :integer, "Maximum number of events", required: true)
    end

    response(200, "OK", Schema.ref(:PubEventList))
    response(400, "Bad Request")
  end

  @doc """
  GET /api/events - Query events by specifying NIP-01 filter parameters in the URL query string.

  # Required Parameters

  The `since`, `until`, and `limit` parameters are required. This ensures every query generates a
  unique, repeatable response. Queries that do not specify `since`, `until`, or `limit` should be
  made against POST /api/events/filter.
  """
  def index(conn, params) do
    with {:ok, filter_map} <- parse_query_params(params),
         {:ok, events} <- Nostr.query_events(filter_map) do
      render(conn, :index, events: events)
    end
  end

  swagger_path :query do
    post("/api/events/filter")
    summary("Query events using a JSON filter in the request body.")

    description("""
      Returns a list of events matching the filter in descending order of created_at time.
      Response is returned as a batch, not streamed, so a `limit` parameter is required to prevent
      the response from getting too large.
    """)

    tag("Events")
    operation_id("filter_events")
    response(200, "OK", Schema.ref(:PubEventList))
    response(400, "Bad Request")
  end

  @doc """
  POST /api/events/filter - Query events using a JSON filter in the request body.
  """
  def query(conn, filter_params) do
    with {:ok, filter} <- validate_required_params(filter_params),
         {:ok, filter} <- validate_param_values(filter),
         {:ok, events} <- Nostr.query_events(filter) do
      render(conn, :index, events: events)
    end
  end

  @spec validate_required_params(map()) :: {:ok, map()} | {:error, String.t()}
  def validate_required_params(params) do
    if Map.has_key?(params, "limit") do
      {:ok, params}
    else
      {:error, "The filter must specify a limit."}
    end
  end

  @spec validate_param_values(map()) :: {:ok, map()} | {:error, String.t()}
  def validate_param_values(params) do
    with {:ok, limit} <- parse_limit_value(Map.get(params, "limit")) do
      if limit < 1 or limit > 100 do
        {:error, "The filter limit must be between 1 and 100."}
      else
        {:ok, Map.put(params, "limit", limit)}
      end
    end
  end

  defp parse_limit_value(v) when is_integer(v), do: {:ok, v}

  defp parse_limit_value(v) when is_binary(v) do
    case Integer.parse(v) do
      {int, ""} -> {:ok, int}
      _ -> {:error, "Invalid limit value: must be an integer"}
    end
  end

  defp parse_limit_value(_), do: {:error, "Invalid limit value: must be an integer"}

  # Parse query parameters into a NIP-01 filter map
  @spec parse_query_params(map()) :: {:ok, map()} | {:error, String.t()}
  defp parse_query_params(params) do
    # Require since, until, and limit for client-side caching and predictable pagination
    with :ok <- require_param(params, "since"),
         :ok <- require_param(params, "until"),
         :ok <- require_param(params, "limit"),
         {:ok, recognized_params} <- validate_known_params(params) do
      parse_params(recognized_params)
    end
  end

  # Ensure a required parameter is present
  @spec require_param(map(), String.t()) :: :ok | {:error, String.t()}
  defp require_param(params, key) do
    if Map.has_key?(params, key) do
      :ok
    else
      {:error, "Missing required parameter: '#{key}'"}
    end
  end

  # Validate that only known NIP-01 filter keys are present
  @spec validate_known_params(map()) :: {:ok, map()} | {:error, String.t()}
  defp validate_known_params(params) do
    known_keys = ["ids", "authors", "kinds", "since", "until", "limit"]

    unknown_keys =
      params
      |> Map.keys()
      |> Enum.reject(fn key ->
        key in known_keys or String.starts_with?(key, "#") or
          (byte_size(key) == 1 and
             ((key >= "a" and key <= "z") or (key >= "A" and key <= "Z")))
      end)

    case unknown_keys do
      [] -> {:ok, params}
      [key | _] -> {:error, "Unknown query parameter: '#{key}'"}
    end
  end

  # Parse individual parameters from strings to proper types
  @spec parse_params(map()) :: {:ok, map()} | {:error, String.t()}
  defp parse_params(params) do
    params
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case parse_param(key, value) do
        {:ok, parsed_value} ->
          out_key = parse_tag(key)

          {:cont, {:ok, Map.put(acc, out_key, parsed_value)}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  # Bare `p=` / `P=` and `#p` / `#P` map to NIP-01 tag filters; letter case is significant (NIP-22).
  @spec parse_tag(String.t()) :: String.t()
  defp parse_tag(key) do
    cond do
      single_bare_letter_tag_key?(key) ->
        "#" <> key

      single_letter_hash_tag_key?(key) ->
        key

      true ->
        key
    end
  end

  defp single_bare_letter_tag_key?(key) do
    String.length(key) == 1 and String.match?(key, ~r/^[a-zA-Z]$/)
  end

  defp single_letter_hash_tag_key?(key) do
    String.starts_with?(key, "#") and String.length(key) == 2 and
      String.match?(String.at(key, 1), ~r/^[a-zA-Z]$/)
  end

  # Parse individual parameter based on its key
  @spec parse_param(String.t(), String.t()) :: {:ok, any()} | {:error, String.t()}
  defp parse_param("ids", value), do: {:ok, String.split(value, ",")}
  defp parse_param("authors", value), do: {:ok, String.split(value, ",")}

  defp parse_param("kinds", value) do
    value
    |> String.split(",")
    |> Enum.reduce_while({:ok, []}, fn kind_str, {:ok, acc} ->
      case Integer.parse(kind_str) do
        {kind, ""} -> {:cont, {:ok, [kind | acc]}}
        _ -> {:halt, {:error, "Invalid kind value: '#{kind_str}' must be an integer"}}
      end
    end)
    |> case do
      {:ok, kinds} -> {:ok, Enum.reverse(kinds)}
      error -> error
    end
  end

  defp parse_param("since", value) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      _ -> {:error, "Invalid since value: '#{value}' must be an integer"}
    end
  end

  defp parse_param("until", value) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      _ -> {:error, "Invalid until value: '#{value}' must be an integer"}
    end
  end

  defp parse_param("limit", value) do
    case Integer.parse(value) do
      {int, ""} when int >= 1 and int <= 100 -> {:ok, int}
      {int, ""} when is_integer(int) -> {:error, "The limit must be between 1 and 100."}
      _ -> {:error, "Invalid limit value: '#{value}' must be an integer"}
    end
  end

  # Handle tag parameters (keys starting with "#")
  defp parse_param("#" <> _tag_name, value) do
    {:ok, String.split(value, ",")}
  end

  # Handle single-letter tag filters without "#" prefix (e.g., "p" instead of "#p")
  # The "#" is trimmed by URL fragment parsing; bare single-letter keys are treated as tag filters
  defp parse_param(<<letter>> = _key, value) when letter in ?a..?z or letter in ?A..?Z do
    {:ok, String.split(value, ",")}
  end
end
