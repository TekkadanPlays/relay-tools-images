defmodule GcIndexRelayWeb.Plugs.RelayInfo do
  @moduledoc """
  Serves the NIP-11 relay information document.

  When a GET / request arrives with `Accept: application/nostr+json`, this plug
  intercepts it and returns the relay metadata as JSON before the browser pipeline's
  `:accepts` check can reject it with a 406.

  Configuration is read from `config :gc_index_relay, :relay_info` — edit that key
  in config/config.exs to describe your relay instance.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(%Plug.Conn{method: "GET", request_path: "/"} = conn, _opts) do
    accept = conn |> get_req_header("accept") |> Enum.join(",")

    if String.contains?(accept, "application/nostr+json") do
      base_url = build_base_url(conn)

      relay_info =
        Application.get_env(:gc_index_relay, :relay_info, [])
        |> Map.new()
        |> resolve_image_urls(base_url)

      conn
      |> put_resp_content_type("application/nostr+json")
      |> send_resp(200, Jason.encode!(relay_info))
      |> halt()
    else
      conn
    end
  end

  def call(conn, _opts), do: conn

  # Build "scheme://host[:port]" from the incoming request.
  # Standard ports (80 for http, 443 for https) are omitted.
  defp build_base_url(conn) do
    port_suffix =
      case {conn.scheme, conn.port} do
        {:http, 80} -> ""
        {:https, 443} -> ""
        {_, port} -> ":#{port}"
      end

    "#{conn.scheme}://#{conn.host}#{port_suffix}"
  end

  # Prepend base_url to any relative (non-absolute) value for :icon and :banner.
  defp resolve_image_urls(relay_info, base_url) do
    relay_info
    |> resolve_field(:icon, base_url)
    |> resolve_field(:banner, base_url)
  end

  defp resolve_field(map, key, base_url) do
    case Map.get(map, key) do
      nil ->
        map

      "" ->
        map

      url when is_binary(url) ->
        resolve_url_field(map, key, url, base_url)

      _ ->
        map
    end
  end

  defp resolve_url_field(map, key, url, base_url) do
    if String.starts_with?(url, ["http://", "https://"]) do
      map
    else
      Map.put(map, key, "#{base_url}#{path_under_base(url)}")
    end
  end

  defp path_under_base(url) do
    if String.starts_with?(url, "/"), do: url, else: "/#{url}"
  end
end
