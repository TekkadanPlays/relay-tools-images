defmodule GcIndexRelayWeb.Plugs.CommunityContext do
  @moduledoc """
  Extracts the Nostr community context from the HTTP request and assigns it to the connection.
  This allows downstream controllers to automatically partition database queries and writes.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    # Extract community from path params (e.g. /api/c/gaming/...)
    community_atag = conn.path_params["community"]

    if community_atag do
      assign(conn, :community_atag, community_atag)
    else
      conn
    end
  end
end
