defmodule GcIndexRelayWeb.FilterControllerTest do
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

  describe "GET /api/events (index)" do
    test "returns empty list when no events exist", %{conn: conn} do
      conn = get(conn, ~p"/api/events?since=0&until=9999999999&limit=10")

      assert %{"data" => []} = json_response(conn, 200)
    end

    test "returns events within time range", %{conn: conn} do
      event_fixture(%{created_at: 1_640_000_100})
      conn = get(conn, ~p"/api/events?since=0&until=9999999999&limit=10")

      assert %{"data" => events} = json_response(conn, 200)
      assert length(events) == 1
    end

    test "filters by authors", %{conn: conn} do
      %{keypair1: keypair1, keypair2: keypair2} = test_keypairs()
      event_fixture(%{keypair: :keypair1})
      event_fixture(%{keypair: :keypair2})

      conn =
        get(
          conn,
          ~p"/api/events?since=0&until=9999999999&limit=10&authors=#{keypair1.public_key_hex}"
        )

      assert %{"data" => events} = json_response(conn, 200)
      assert length(events) == 1
      assert hd(events)["pubkey"] == keypair1.public_key_hex
      assert hd(events)["pubkey"] != keypair2.public_key_hex
    end

    test "filters by kinds", %{conn: conn} do
      event_fixture(%{kind: 1})
      event_fixture(%{kind: 2})
      conn = get(conn, ~p"/api/events?since=0&until=9999999999&limit=10&kinds=1")

      assert %{"data" => events} = json_response(conn, 200)
      assert length(events) == 1
      assert hd(events)["kind"] == 1
    end

    test "filters by ids", %{conn: conn} do
      event1 = event_fixture(%{kind: 1})
      _event2 = event_fixture(%{kind: 2, created_at: 1_640_000_001})
      hex_id1 = Base.encode16(event1.id, case: :lower)

      conn = get(conn, ~p"/api/events?since=0&until=9999999999&limit=10&ids=#{hex_id1}")

      assert %{"data" => events} = json_response(conn, 200)
      assert length(events) == 1
      assert hd(events)["id"] == hex_id1
    end

    test "filters by tags", %{conn: conn} do
      tagged_pub_event = valid_pub_event_fixture(%{tags: [["p", "abc123def456"]]})
      {:ok, _} = GcIndexRelay.Nostr.create_event(tagged_pub_event)
      event_fixture(%{kind: 2, created_at: 1_640_000_001})

      conn = get(conn, ~p"/api/events?since=0&until=9999999999&limit=10&p=abc123def456")

      assert %{"data" => events} = json_response(conn, 200)
      assert length(events) == 1
      assert hd(events)["id"] == tagged_pub_event.id
    end

    test "filters by uppercase P tag separately from lowercase p (NIP-22)", %{conn: conn} do
      upper = valid_pub_event_fixture(%{tags: [["P", "abc123def456"]]})
      {:ok, _} = GcIndexRelay.Nostr.create_event(upper)

      lower = valid_pub_event_fixture(%{tags: [["p", "abc123def456"]], keypair: :keypair2})
      {:ok, _} = GcIndexRelay.Nostr.create_event(lower)

      event_fixture(%{kind: 2, created_at: 1_640_000_002})

      conn_p = get(conn, ~p"/api/events?since=0&until=9999999999&limit=10&p=abc123def456")
      assert %{"data" => p_events} = json_response(conn_p, 200)
      assert Enum.map(p_events, & &1["id"]) == [lower.id]

      conn_upper_p = get(conn, ~p"/api/events?since=0&until=9999999999&limit=10&P=abc123def456")
      assert %{"data" => p_upper_events} = json_response(conn_upper_p, 200)
      assert Enum.map(p_upper_events, & &1["id"]) == [upper.id]
    end

    test "respects limit parameter", %{conn: conn} do
      event_fixture(%{kind: 1})
      event_fixture(%{kind: 2, created_at: 1_640_000_001})
      event_fixture(%{kind: 3, created_at: 1_640_000_002})
      conn = get(conn, ~p"/api/events?since=0&until=9999999999&limit=2")

      assert %{"data" => events} = json_response(conn, 200)
      assert length(events) == 2
    end

    test "returns 400 when since is missing", %{conn: conn} do
      conn = get(conn, ~p"/api/events?until=9999999999&limit=10")

      assert json_response(conn, 400)
    end

    test "returns 400 when until is missing", %{conn: conn} do
      conn = get(conn, ~p"/api/events?since=0&limit=10")

      assert json_response(conn, 400)
    end

    test "returns 400 when limit is missing", %{conn: conn} do
      conn = get(conn, ~p"/api/events?since=0&until=9999999999")

      assert json_response(conn, 400)
    end

    test "returns 400 when limit is too large", %{conn: conn} do
      conn = get(conn, ~p"/api/events?since=0&until=9999999999&limit=101")

      assert json_response(conn, 400)
    end

    test "returns 400 for unknown query parameter", %{conn: conn} do
      conn = get(conn, ~p"/api/events?since=0&until=9999999999&limit=10&unknown=foo")

      assert json_response(conn, 400)
    end

    test "returns 400 for invalid (non-integer) limit value", %{conn: conn} do
      conn = get(conn, ~p"/api/events?since=0&until=9999999999&limit=abc")

      assert json_response(conn, 400)
    end

    test "returns 400 for invalid (non-integer) since value", %{conn: conn} do
      conn = get(conn, ~p"/api/events?since=not_a_number&until=9999999999&limit=10")

      assert json_response(conn, 400)
    end
  end

  describe "POST /api/events/filter (query)" do
    test "returns empty list when no events exist", %{conn: conn} do
      conn = post(conn, ~p"/api/events/filter", %{"limit" => 10})

      assert %{"data" => []} = json_response(conn, 200)
    end

    test "returns events with only limit specified", %{conn: conn} do
      event_fixture()
      conn = post(conn, ~p"/api/events/filter", %{"limit" => 10})

      assert %{"data" => events} = json_response(conn, 200)
      assert not Enum.empty?(events)
      assert length(events) <= 10
    end

    test "filters by authors", %{conn: conn} do
      %{keypair1: keypair1, keypair2: keypair2} = test_keypairs()
      event_fixture(%{keypair: :keypair1})
      event_fixture(%{keypair: :keypair2})

      conn =
        post(conn, ~p"/api/events/filter", %{
          "authors" => [keypair1.public_key_hex],
          "limit" => 10
        })

      assert %{"data" => events} = json_response(conn, 200)
      assert length(events) == 1
      assert hd(events)["pubkey"] == keypair1.public_key_hex
      assert hd(events)["pubkey"] != keypair2.public_key_hex
    end

    test "filters by kinds", %{conn: conn} do
      event_fixture(%{kind: 1})
      event_fixture(%{kind: 2, created_at: 1_640_000_001})

      conn = post(conn, ~p"/api/events/filter", %{"kinds" => [1], "limit" => 10})

      assert %{"data" => events} = json_response(conn, 200)
      assert length(events) == 1
      assert hd(events)["kind"] == 1
    end

    test "filters by ids", %{conn: conn} do
      pub_event = valid_pub_event_fixture()
      event_fixture(%{kind: 2, created_at: 1_640_000_001})
      {:ok, _} = GcIndexRelay.Nostr.create_event(pub_event)

      conn =
        post(conn, ~p"/api/events/filter", %{
          "ids" => [pub_event.id],
          "limit" => 10
        })

      assert %{"data" => events} = json_response(conn, 200)
      assert length(events) == 1
      assert hd(events)["id"] == pub_event.id
    end

    test "filters by since timestamp", %{conn: conn} do
      event_fixture(%{created_at: 1_639_999_999})
      event_fixture(%{kind: 2, created_at: 1_640_000_100})

      conn =
        post(conn, ~p"/api/events/filter", %{
          "since" => 1_640_000_000,
          "limit" => 10
        })

      assert %{"data" => events} = json_response(conn, 200)
      assert length(events) == 1
      assert hd(events)["created_at"] == 1_640_000_100
    end

    test "filters by until timestamp", %{conn: conn} do
      event_fixture(%{created_at: 1_639_999_999})
      event_fixture(%{kind: 2, created_at: 1_640_000_100})

      conn =
        post(conn, ~p"/api/events/filter", %{
          "until" => 1_640_000_000,
          "limit" => 10
        })

      assert %{"data" => events} = json_response(conn, 200)
      assert length(events) == 1
      assert hd(events)["created_at"] == 1_639_999_999
    end

    test "filters by tags", %{conn: conn} do
      tagged_pub_event = valid_pub_event_fixture(%{tags: [["p", "abc123def456"]]})
      {:ok, _} = GcIndexRelay.Nostr.create_event(tagged_pub_event)
      event_fixture(%{kind: 2, created_at: 1_640_000_001})

      conn =
        post(conn, ~p"/api/events/filter", %{
          "#p" => ["abc123def456"],
          "limit" => 10
        })

      assert %{"data" => events} = json_response(conn, 200)
      assert length(events) == 1
      assert hd(events)["id"] == tagged_pub_event.id
    end

    test "POST filter #P matches uppercase P tag only, not lowercase p", %{conn: conn} do
      upper = valid_pub_event_fixture(%{tags: [["P", "abc123def456"]]})
      {:ok, _} = GcIndexRelay.Nostr.create_event(upper)

      lower = valid_pub_event_fixture(%{tags: [["p", "abc123def456"]], keypair: :keypair2})
      {:ok, _} = GcIndexRelay.Nostr.create_event(lower)

      event_fixture(%{kind: 2, created_at: 1_640_000_002})

      conn_upper_p =
        post(conn, ~p"/api/events/filter", %{
          "#P" => ["abc123def456"],
          "limit" => 10
        })

      assert %{"data" => p_upper} = json_response(conn_upper_p, 200)
      assert Enum.map(p_upper, & &1["id"]) == [upper.id]

      conn_p =
        post(conn, ~p"/api/events/filter", %{
          "#p" => ["abc123def456"],
          "limit" => 10
        })

      assert %{"data" => p_lower} = json_response(conn_p, 200)
      assert Enum.map(p_lower, & &1["id"]) == [lower.id]
    end

    test "respects limit parameter", %{conn: conn} do
      event_fixture(%{kind: 1})
      event_fixture(%{kind: 2, created_at: 1_640_000_001})
      event_fixture(%{kind: 3, created_at: 1_640_000_002})

      conn = post(conn, ~p"/api/events/filter", %{"limit" => 2})

      assert %{"data" => events} = json_response(conn, 200)
      assert length(events) == 2
    end

    test "returns results in descending created_at order", %{conn: conn} do
      event_fixture(%{kind: 1, created_at: 1_640_000_001})
      event_fixture(%{kind: 2, created_at: 1_640_000_002})
      event_fixture(%{kind: 3, created_at: 1_640_000_003})

      conn = post(conn, ~p"/api/events/filter", %{"limit" => 10})

      assert %{"data" => events} = json_response(conn, 200)
      created_ats = Enum.map(events, & &1["created_at"])
      assert created_ats == Enum.sort(created_ats, :desc)
    end

    test "returns 400 when limit is missing", %{conn: conn} do
      conn = post(conn, ~p"/api/events/filter", %{"kinds" => [1]})

      assert json_response(conn, 400)
    end

    test "returns 400 when limit is 0", %{conn: conn} do
      conn = post(conn, ~p"/api/events/filter", %{"limit" => 0})

      assert json_response(conn, 400)
    end

    test "returns 400 when limit exceeds 100", %{conn: conn} do
      conn = post(conn, ~p"/api/events/filter", %{"limit" => 101})

      assert json_response(conn, 400)
    end
  end
end
