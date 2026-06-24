defmodule GcIndexRelayWeb.Plugs.WebSocketUpgrade do
  @moduledoc """
  Intercepts standard HTTP requests and upgrades them to raw WebSockets for NIP-01.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    if get_req_header(conn, "upgrade") == ["websocket"] do
      conn
      |> upgrade_adapter(:websocket, {GcIndexRelayWeb.NostrSocket, [], []})
      |> halt()
    else
      conn
    end
  end
end
