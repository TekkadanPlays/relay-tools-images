defmodule GcIndexRelayWeb.PublicationContentSearchControllerTest do
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

  defp insert_content!(d, body) do
    event =
      valid_pub_event_fixture(%{
        kind: 30_041,
        content: body,
        tags: [["d", d]]
      })

    assert {:ok, _} = Nostr.create_event(event)
    event
  end

  describe "POST /api/publications/content/search" do
    test "returns matching kind-30041 events by phrase", %{conn: conn} do
      pub_event =
        insert_content!(
          "pg1342-ch-1",
          "It is a truth universally acknowledged, that a single man in possession of a good fortune."
        )

      conn =
        post(conn, ~p"/api/publications/content/search", %{
          "q" => "truth universally acknowledged",
          "limit" => 10
        })

      assert %{"data" => [event]} = json_response(conn, 200)
      assert event["id"] == pub_event.id
      assert event["kind"] == 30_041
    end

    test "quoted query requires contiguous phrase", %{conn: conn} do
      insert_content!("pg1342-ch-1", "truth universally acknowledged by everyone")

      conn =
        post(conn, ~p"/api/publications/content/search", %{
          "q" => "\"truth acknowledged\"",
          "limit" => 10
        })

      assert %{"data" => []} = json_response(conn, 200)
    end

    test "returns empty list when nothing matches", %{conn: conn} do
      insert_content!("pg1342-ch-1", "Some chapter text.")

      conn =
        post(conn, ~p"/api/publications/content/search", %{
          "q" => "zzzznotfound",
          "limit" => 10
        })

      assert %{"data" => []} = json_response(conn, 200)
    end

    test "returns 400 when q is missing", %{conn: conn} do
      conn = post(conn, ~p"/api/publications/content/search", %{"limit" => 10})

      assert %{"errors" => %{"detail" => "Missing required field: q"}} = json_response(conn, 400)
    end
  end
end
