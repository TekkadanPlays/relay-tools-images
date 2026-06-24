defmodule GcIndexRelayWeb.Plugs.CORS do
  @moduledoc """
  CORS plug for the Nostr relay REST API.

  Configure under `:cors` for `:gc_index_relay` (see `config/config.exs`).

  * `enabled` — when `false`, the plug is a no-op (use when a reverse proxy handles CORS).
  * `allow_origins` — `\"*\"` or a list of exact `Origin` values to echo back.
  * `allow_methods` / `allow_headers` — forwarded as response headers when CORS applies.

  Preflight `OPTIONS` requests are halted with 200 when CORS is enabled; when disabled,
  they continue to the router.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    cors = Application.get_env(:gc_index_relay, :cors, [])

    if Keyword.get(cors, :enabled, true) do
      allow_origins = Keyword.get(cors, :allow_origins, "*")
      allow_methods = Keyword.get(cors, :allow_methods, "GET, POST, DELETE, OPTIONS")
      allow_headers = Keyword.get(cors, :allow_headers, "content-type, authorization")
      origin_value = resolve_allow_origin(conn, allow_origins)

      if origin_value == nil && restrictive_allowlist?(allow_origins) do
        handle_preflight(conn)
      else
        conn
        |> put_resp_header("access-control-allow-origin", origin_value)
        |> put_resp_header("access-control-allow-methods", allow_methods)
        |> put_resp_header("access-control-allow-headers", allow_headers)
        |> handle_preflight()
      end
    else
      conn
    end
  end

  defp resolve_allow_origin(_conn, "*"), do: "*"

  defp resolve_allow_origin(conn, allow_origins) when is_list(allow_origins) do
    if "*" in allow_origins do
      "*"
    else
      origin_from_allowlist(conn, allow_origins)
    end
  end

  defp resolve_allow_origin(_conn, _), do: "*"

  defp origin_from_allowlist(conn, allow_origins) do
    case get_req_header(conn, "origin") do
      [origin] -> origin_if_allowed(origin, allow_origins)
      _ -> nil
    end
  end

  defp origin_if_allowed(origin, allow_origins) do
    if Enum.member?(allow_origins, origin), do: origin, else: nil
  end

  defp restrictive_allowlist?("*"), do: false

  defp restrictive_allowlist?(list) when is_list(list) do
    "*" not in list
  end

  defp restrictive_allowlist?(_), do: false

  defp handle_preflight(%Plug.Conn{method: "OPTIONS"} = conn) do
    conn
    |> send_resp(200, "")
    |> halt()
  end

  defp handle_preflight(conn), do: conn
end
