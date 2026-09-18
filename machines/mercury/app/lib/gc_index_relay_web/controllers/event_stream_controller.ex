defmodule GcIndexRelayWeb.EventStreamController do
  use GcIndexRelayWeb, :controller
  alias GcIndexRelay.Nostr.PubEvent

  @doc """
  GET /api/events/stream
  Opens a Server-Sent Events (SSE) stream for real-time Nostr events.
  Automatically partitioned by community context.
  """
  def stream(conn, _params) do
    community_atag = conn.assigns[:community_atag]

    conn
    |> put_resp_header("content-type", "text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> put_resp_header("connection", "keep-alive")
    |> send_chunked(200)
    |> subscribe_and_stream(community_atag)
  end

  defp subscribe_and_stream(conn, community_atag) do
    # Subscribe to the global events topic
    Phoenix.PubSub.subscribe(GcIndexRelay.PubSub, "events")

    # Send an initial comment to establish the connection
    {:ok, conn} = chunk(conn, ": connected\n\n")

    stream_loop(conn, community_atag)
  end

  defp stream_loop(conn, community_atag) do
    receive do
      {:new_event, %PubEvent{} = event} ->
        if belongs_to_community?(event, community_atag) do
          case chunk(conn, "data: #{Jason.encode!(event)}\n\n") do
            {:ok, conn} -> stream_loop(conn, community_atag)
            {:error, _reason} -> 
              Phoenix.PubSub.unsubscribe(GcIndexRelay.PubSub, "events")
              conn
          end
        else
          stream_loop(conn, community_atag)
        end

      # Handle client disconnects or other unexpected messages
      _ ->
        stream_loop(conn, community_atag)
    end
  end

  defp belongs_to_community?(_event, nil), do: true
  defp belongs_to_community?(event, community_id) do
    Enum.any?(event.tags, fn
      ["a", tag_val | _] -> String.ends_with?(tag_val, ":#{community_id}")
      _ -> false
    end)
  end
end
