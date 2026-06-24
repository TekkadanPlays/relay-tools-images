defmodule GcIndexRelayWeb.EventControllerTest do
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

  describe "POST /api/events" do
    test "returns published event when request succeeds", %{conn: conn} do
      pub_event = valid_pub_event_fixture()
      conn = post(conn, ~p"/api/events", %{"event" => Map.from_struct(pub_event)})

      assert %{"data" => data} = json_response(conn, 201)
      assert data["id"] == pub_event.id
      assert data["pubkey"] == pub_event.pubkey
      assert data["kind"] == pub_event.kind
      assert data["content"] == pub_event.content
      assert data["sig"] == pub_event.sig
    end

    test "returns 409 Conflict for duplicate event", %{conn: conn} do
      pub_event = valid_pub_event_fixture()
      post(conn, ~p"/api/events", %{"event" => Map.from_struct(pub_event)})
      conn = post(conn, ~p"/api/events", %{"event" => Map.from_struct(pub_event)})

      assert json_response(conn, 409)
    end

    test "returns 422 for event with invalid kind", %{conn: conn} do
      pub_event = valid_pub_event_fixture(%{kind: -1})
      conn = post(conn, ~p"/api/events", %{"event" => Map.from_struct(pub_event)})

      assert json_response(conn, 422)
    end

    test "returns 400 for invalid event ID", %{conn: conn} do
      pub_event = invalid_id_pub_event_fixture()
      conn = post(conn, ~p"/api/events", %{"event" => Map.from_struct(pub_event)})

      assert json_response(conn, 400)
    end

    test "returns 400 for invalid signature", %{conn: conn} do
      pub_event = invalid_sig_pub_event_fixture()
      conn = post(conn, ~p"/api/events", %{"event" => Map.from_struct(pub_event)})

      assert json_response(conn, 400)
    end
  end

  describe "GET /api/events/:id" do
    test "returns event when found", %{conn: conn} do
      event = event_fixture()
      hex_id = Base.encode16(event.id, case: :lower)
      conn = get(conn, ~p"/api/events/#{hex_id}")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == hex_id
    end

    test "returns 404 when event not found", %{conn: conn} do
      nonexistent_id = String.duplicate("a", 64)
      conn = get(conn, ~p"/api/events/#{nonexistent_id}")

      assert json_response(conn, 404)
    end
  end

  describe "DELETE /api/events/:id" do
    test "deletes event and returns 204", %{conn: conn} do
      event = event_fixture()
      hex_id = Base.encode16(event.id, case: :lower)
      conn = delete(conn, ~p"/api/events/#{hex_id}")

      assert response(conn, 204)
    end

    test "returns 404 when event not found", %{conn: conn} do
      nonexistent_id = String.duplicate("a", 64)
      conn = delete(conn, ~p"/api/events/#{nonexistent_id}")

      assert json_response(conn, 404)
    end
  end
end
