defmodule GcIndexRelayWeb.PublicationSearchControllerTest do
  use GcIndexRelayWeb.ConnCase

  import GcIndexRelay.NostrFixtures

  alias GcIndexRelay.Nostr

  @moduletag :integration

  setup %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("content-type", "application/json")

    {:ok, conn: conn}
  end

  defp insert_publication!(d, title, author) do
    event =
      valid_pub_event_fixture(%{
        kind: 30_040,
        content: "",
        tags: [
          ["d", d],
          ["title", title],
          ["author", author]
        ]
      })

    assert {:ok, _} = Nostr.create_event(event)
    event
  end

  describe "POST /api/publications/search" do
    test "returns matching kind-30040 events", %{conn: conn} do
      pub_event =
        insert_publication!("pg1342-pride-and-prejudice", "Pride and Prejudice", "Jane Austen")

      conn =
        post(conn, ~p"/api/publications/search", %{
          "q" => "pride and prejudice",
          "limit" => 10
        })

      assert %{"data" => [event]} = json_response(conn, 200)
      assert event["id"] == pub_event.id
      assert event["kind"] == 30_040
    end

    test "returns partial metadata matches", %{conn: conn} do
      pub_event =
        insert_publication!("pg1342-pride-and-prejudice", "Pride and Prejudice", "Jane Austen")

      conn = post(conn, ~p"/api/publications/search", %{"q" => "pg1342", "limit" => 10})

      assert %{"data" => [event]} = json_response(conn, 200)
      assert event["id"] == pub_event.id
    end

    test "returns empty list when nothing matches", %{conn: conn} do
      insert_publication!("pg1342-pride-and-prejudice", "Pride and Prejudice", "Jane Austen")

      conn = post(conn, ~p"/api/publications/search", %{"q" => "zzzznotfound", "limit" => 10})

      assert %{"data" => []} = json_response(conn, 200)
    end

    test "returns 400 when q is missing", %{conn: conn} do
      conn = post(conn, ~p"/api/publications/search", %{"limit" => 10})

      assert %{"errors" => %{"detail" => "Missing required field: q"}} = json_response(conn, 400)
    end

    test "returns 400 when q is empty", %{conn: conn} do
      conn = post(conn, ~p"/api/publications/search", %{"q" => "  ", "limit" => 10})

      assert %{"errors" => %{"detail" => "Query q must not be empty."}} = json_response(conn, 400)
    end

    test "returns 400 when limit is out of range", %{conn: conn} do
      conn = post(conn, ~p"/api/publications/search", %{"q" => "book", "limit" => 0})

      assert %{"errors" => %{"detail" => "The limit must be between 1 and 100."}} =
               json_response(conn, 400)
    end
  end
end
