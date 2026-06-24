defmodule GcIndexRelayWeb.RelayUnitTest do
  @moduledoc """
  Unit tests for relay HTTP endpoints that require no database access.
  Tests controller/plug behaviour: routing, validation rejection, CORS headers,
  NIP-11 relay info, and health check.

  Scenarios are a subset of test/features/relay_api.feature.
  Run with: mix test.unit test/gc_index_relay_web/relay_unit_test.exs
  """

  use GcIndexRelayWeb.ConnCase, async: true

  import GcIndexRelay.NostrFixtures

  @moduletag :unit

  setup %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("content-type", "application/json")

    {:ok, conn: conn}
  end

  # ---------------------------------------------------------------------------
  # Discovery
  # ---------------------------------------------------------------------------

  describe "GET /api — discovery" do
    test "client discovers available endpoints", %{conn: conn} do
      conn = get(conn, ~p"/api")

      assert %{"endpoints" => endpoints} = json_response(conn, 200)
      paths = Enum.map(endpoints, & &1["path"])
      assert "/api/events" in paths
      assert "/api/events/:id" in paths
      assert "/api/events/filter" in paths
    end
  end

  # ---------------------------------------------------------------------------
  # Request validation — rejected before any DB access
  # ---------------------------------------------------------------------------

  describe "POST /api/events — validation rejections" do
    test "relay rejects a NIP-70 protected event with 400", %{conn: conn} do
      event = valid_pub_event_fixture(%{tags: [["-"]]})

      conn = post(conn, ~p"/api/events", %{"event" => Map.from_struct(event)})

      assert %{"errors" => %{"detail" => detail}} = json_response(conn, 400)
      assert detail =~ "auth-required"
    end
  end

  # ---------------------------------------------------------------------------
  # CORS — required for browser-based clients like Jumble
  # ---------------------------------------------------------------------------

  describe "CORS headers — browser client compatibility" do
    test "relay includes CORS headers on a GET response", %{conn: conn} do
      conn = get(conn, ~p"/api")

      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      methods = get_resp_header(conn, "access-control-allow-methods") |> List.first("")
      assert methods =~ "GET"
      assert methods =~ "POST"
      assert methods =~ "DELETE"
      assert methods =~ "OPTIONS"
    end

    test "relay includes CORS headers on a POST response", %{conn: conn} do
      # Reject before DB (NIP-70 protected) so unit tests need no running Repo.
      event = valid_pub_event_fixture(%{tags: [["-"]]})
      conn = post(conn, ~p"/api/events", %{"event" => Map.from_struct(event)})

      assert json_response(conn, 400)
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
    end

    test "relay responds 200 to a browser preflight OPTIONS request", %{conn: conn} do
      conn = options(conn, "/api/events")

      assert conn.status == 200
      assert conn.resp_body == ""
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
      methods = get_resp_header(conn, "access-control-allow-methods") |> List.first("")
      assert methods =~ "OPTIONS"
    end
  end

  # ---------------------------------------------------------------------------
  # NIP-11 relay information document
  # ---------------------------------------------------------------------------

  describe "GET / with Accept: application/nostr+json — NIP-11" do
    test "returns 200 with application/nostr+json content-type", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "application/nostr+json")
        |> get("/")

      assert conn.status == 200
      [content_type | _] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/nostr+json"
    end

    test "response body is valid JSON with required NIP-11 fields", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "application/nostr+json")
        |> get("/")

      assert {:ok, body} = Jason.decode(conn.resp_body)
      assert is_binary(body["name"])
      assert is_list(body["supported_nips"])
      assert is_map(body["limitation"])
      assert is_binary(body["icon"]) and String.starts_with?(body["icon"], "http")
    end

    test "supported_nips list includes NIP-11 and NIP-70", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "application/nostr+json")
        |> get("/")

      assert {:ok, %{"supported_nips" => nips}} = Jason.decode(conn.resp_body)
      assert 11 in nips
      assert 70 in nips
    end

    test "limitation object contains expected fields", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "application/nostr+json")
        |> get("/")

      assert {:ok, %{"limitation" => limitation}} = Jason.decode(conn.resp_body)
      assert Map.has_key?(limitation, "max_limit")
      assert Map.has_key?(limitation, "auth_required")
      assert Map.has_key?(limitation, "payment_required")
    end

    test "NIP-11 response includes CORS headers", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "application/nostr+json")
        |> get("/")

      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
    end

    test "regular browser request to GET / still returns HTML", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "text/html,application/xhtml+xml")
        |> get("/")

      assert conn.status == 200
      [content_type | _] = get_resp_header(conn, "content-type")
      assert content_type =~ "text/html"
    end
  end

  # ---------------------------------------------------------------------------
  # Health check
  # ---------------------------------------------------------------------------

  describe "GET /health — health check" do
    test "health check returns 200", %{conn: conn} do
      conn = get(conn, "/health")
      assert conn.status == 200
    end
  end
end
