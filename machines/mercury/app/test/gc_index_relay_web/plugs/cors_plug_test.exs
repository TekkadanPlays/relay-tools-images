defmodule GcIndexRelayWeb.Plugs.CorsPlugTest do
  @moduledoc false
  use GcIndexRelayWeb.ConnCase, async: false

  @moduletag :unit

  setup do
    previous = Application.get_env(:gc_index_relay, :cors)
    on_exit(fn -> Application.put_env(:gc_index_relay, :cors, previous) end)
    {:ok, previous_cors: previous}
  end

  describe "allow_origins allowlist" do
    setup %{previous_cors: previous} do
      base = previous || []

      Application.put_env(
        :gc_index_relay,
        :cors,
        Keyword.merge(base,
          enabled: true,
          allow_origins: ["https://client.example.com"]
        )
      )

      :ok
    end

    test "reflects Origin when it matches the allowlist", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> put_req_header("origin", "https://client.example.com")
        |> get(~p"/api")

      assert get_resp_header(conn, "access-control-allow-origin") == [
               "https://client.example.com"
             ]
    end

    test "omits Access-Control-Allow-Origin when Origin does not match", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> put_req_header("origin", "https://evil.example.com")
        |> get(~p"/api")

      assert get_resp_header(conn, "access-control-allow-origin") == []
    end

    test "preflight without matching Origin has no CORS allow headers", %{conn: conn} do
      conn =
        conn
        |> put_req_header("origin", "https://evil.example.com")
        |> options("/api/events")

      assert conn.status == 200
      assert conn.resp_body == ""
      assert get_resp_header(conn, "access-control-allow-origin") == []
    end
  end

  describe "CORS disabled" do
    setup %{previous_cors: previous} do
      base = previous || []
      Application.put_env(:gc_index_relay, :cors, Keyword.merge(base, enabled: false))
      :ok
    end

    test "does not set CORS headers on GET", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> get(~p"/api")

      assert get_resp_header(conn, "access-control-allow-origin") == []
    end

    test "does not handle OPTIONS preflight (no CORS headers)", %{conn: conn} do
      conn = options(conn, "/api/events")

      assert get_resp_header(conn, "access-control-allow-origin") == []
    end
  end
end
