defmodule GcIndexRelayWeb.PageControllerTest do
  use GcIndexRelayWeb.ConnCase

  @moduletag :unit

  test "GET / renders Mercury landing page", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Mercury Index-Relay"
  end
end
