defmodule GcIndexRelayWeb.RelayIntegrationTest do
  @moduledoc """
  Integration tests for relay REST API scenarios that require a live database.
  Covers event publishing, deletion, and filter-based querying.

  Scenarios are mapped 1:1 to test/features/relay_api.feature.
  Run with: source .env && mix test.integration test/gc_index_relay_web/relay_integration_test.exs
  """

  use GcIndexRelayWeb.ConnCase

  import GcIndexRelay.NostrFixtures

  @moduletag :integration

  setup %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("content-type", "application/json")

    {:ok, conn: conn}
  end

  # ---------------------------------------------------------------------------
  # Publishing events (POST /api/events)
  # ---------------------------------------------------------------------------

  describe "POST /api/events — publishing" do
    test "client publishes a valid kind 1 note", %{conn: conn} do
      event = valid_pub_event_fixture(%{kind: 1, content: "hello nostr"})

      conn = post(conn, ~p"/api/events", %{"event" => Map.from_struct(event)})

      assert %{"data" => data} = json_response(conn, 201)
      assert data["id"] == event.id
      assert data["kind"] == 1
      assert data["content"] == "hello nostr"
    end

    test "client publishes a kind 0 profile event with metadata content", %{conn: conn} do
      metadata = Jason.encode!(%{name: "testuser", about: "a test profile", picture: ""})
      event = valid_pub_event_fixture(%{kind: 0, content: metadata})

      conn = post(conn, ~p"/api/events", %{"event" => Map.from_struct(event)})

      assert %{"data" => data} = json_response(conn, 201)
      assert data["kind"] == 0
      assert data["content"] == metadata
    end

    test "relay rejects a duplicate event with 409", %{conn: conn} do
      event = valid_pub_event_fixture()
      post(conn, ~p"/api/events", %{"event" => Map.from_struct(event)})

      conn = post(conn, ~p"/api/events", %{"event" => Map.from_struct(event)})

      assert json_response(conn, 409)
    end
  end

  # ---------------------------------------------------------------------------
  # Deleting events (DELETE /api/events/:id)
  # ---------------------------------------------------------------------------

  describe "DELETE /api/events/:id — deletion" do
    test "client deletes an existing event and gets 204", %{conn: conn} do
      event = valid_pub_event_fixture()
      {:ok, db_event} = GcIndexRelay.Nostr.create_event(event)
      hex_id = Base.encode16(db_event.id, case: :lower)

      conn = delete(conn, ~p"/api/events/#{hex_id}")

      assert conn.status == 204
      assert conn.resp_body == ""
    end

    test "deleting a non-existent event returns 404", %{conn: conn} do
      conn = delete(conn, ~p"/api/events/#{String.duplicate("b", 64)}")

      assert json_response(conn, 404)
    end
  end

  # ---------------------------------------------------------------------------
  # Querying events (GET /api/events — cacheable with query params)
  # ---------------------------------------------------------------------------

  describe "GET /api/events — cacheable query" do
    test "client fetches events with since/until/limit query params", %{conn: conn} do
      valid_pub_event_fixture(%{kind: 1, created_at: 1_640_000_001})
      |> then(&GcIndexRelay.Nostr.create_event/1)

      valid_pub_event_fixture(%{kind: 1, created_at: 1_640_000_002, keypair: :keypair2})
      |> then(&GcIndexRelay.Nostr.create_event/1)

      conn = get(conn, "/api/events?since=0&until=9999999999&limit=10")

      assert %{"data" => events} = json_response(conn, 200)
      assert length(events) == 2
      [first, second] = events
      assert first["created_at"] >= second["created_at"]
    end
  end

  # ---------------------------------------------------------------------------
  # Querying events (POST /api/events/filter)
  # ---------------------------------------------------------------------------

  describe "POST /api/events/filter — querying" do
    test "client fetches recent kind 1 notes, newest first", %{conn: conn} do
      valid_pub_event_fixture(%{kind: 1, created_at: 1_640_000_001})
      |> then(&GcIndexRelay.Nostr.create_event/1)

      valid_pub_event_fixture(%{kind: 1, created_at: 1_640_000_002, keypair: :keypair2})
      |> then(&GcIndexRelay.Nostr.create_event/1)

      conn = post(conn, ~p"/api/events/filter", %{"kinds" => [1], "limit" => 10})

      assert %{"data" => events} = json_response(conn, 200)
      assert length(events) == 2
      [first, second] = events
      assert first["created_at"] >= second["created_at"]
    end

    test "client fetches a user profile (kind 0) by author", %{conn: conn} do
      %{keypair1: kp} = test_keypairs()
      metadata = Jason.encode!(%{name: "alice"})
      event = valid_pub_event_fixture(%{kind: 0, content: metadata})
      {:ok, _} = GcIndexRelay.Nostr.create_event(event)

      conn =
        post(conn, ~p"/api/events/filter", %{
          "kinds" => [0],
          "authors" => [kp.public_key_hex],
          "limit" => 1
        })

      assert %{"data" => [profile]} = json_response(conn, 200)
      assert profile["kind"] == 0
      assert profile["pubkey"] == kp.public_key_hex
    end

    test "client fetches events mentioning a pubkey via #p tag", %{conn: conn} do
      mentioned_pubkey = String.duplicate("ab", 32)
      event = valid_pub_event_fixture(%{tags: [["p", mentioned_pubkey]]})
      {:ok, _} = GcIndexRelay.Nostr.create_event(event)

      valid_pub_event_fixture(%{created_at: 1_640_000_001, keypair: :keypair2})
      |> then(&GcIndexRelay.Nostr.create_event/1)

      conn = post(conn, ~p"/api/events/filter", %{"#p" => [mentioned_pubkey], "limit" => 10})

      assert %{"data" => events} = json_response(conn, 200)
      assert length(events) == 1
      assert hd(events)["id"] == event.id
    end

    test "client fetches events within a time window", %{conn: conn} do
      valid_pub_event_fixture(%{kind: 1, created_at: 1_500_000_000})
      |> then(&GcIndexRelay.Nostr.create_event/1)

      valid_pub_event_fixture(%{kind: 1, created_at: 1_640_000_001, keypair: :keypair2})
      |> then(&GcIndexRelay.Nostr.create_event/1)

      conn =
        post(conn, ~p"/api/events/filter", %{
          "since" => 1_600_000_000,
          "limit" => 10
        })

      assert %{"data" => events} = json_response(conn, 200)
      assert length(events) == 1
      assert hd(events)["created_at"] == 1_640_000_001
    end
  end

  # ---------------------------------------------------------------------------
  # Fetching a single event (GET /api/events/:id)
  # ---------------------------------------------------------------------------

  describe "GET /api/events/:id — single event lookup" do
    test "client fetches a specific event by ID", %{conn: conn} do
      event = valid_pub_event_fixture()
      {:ok, db_event} = GcIndexRelay.Nostr.create_event(event)
      hex_id = Base.encode16(db_event.id, case: :lower)

      conn = get(conn, ~p"/api/events/#{hex_id}")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == hex_id
      assert data["content"] == event.content
    end

    test "fetching a non-existent event returns 404", %{conn: conn} do
      conn = get(conn, ~p"/api/events/#{String.duplicate("a", 64)}")

      assert json_response(conn, 404)
    end
  end
end
