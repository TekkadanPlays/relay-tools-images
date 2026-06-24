defmodule GcIndexRelayWeb.EventController do
  use GcIndexRelayWeb, :controller
  use PhoenixSwagger

  alias GcIndexRelay.Nostr
  alias GcIndexRelay.Nostr.Event
  alias GcIndexRelay.Nostr.PubEvent

  action_fallback GcIndexRelayWeb.FallbackController

  swagger_path :create do
    post("/api/events")
    summary("Publish a Nostr event")
    description("Accepts a signed Nostr event JSON. Event ID and signature are validated.")
    produces("application/json")
    tag("Events")
    operation_id("create_event")
    response(201, "Created", Schema.ref(:PubEvent))
    response(400, "BadRequest")
  end

  @pub_event_keys ~w(id pubkey created_at kind tags content sig)

  def create(conn, %{"event" => event_params}) do
    pub_event =
      @pub_event_keys
      |> Enum.reduce(%{}, fn key, acc ->
        case Map.get(event_params, key) do
          nil -> acc
          v -> Map.put(acc, String.to_existing_atom(key), v)
        end
      end)
      |> Map.put_new(:tags, [])
      |> Map.put_new(:content, "")
      |> then(&struct(PubEvent, &1))

    with {:ok, _event} <- Nostr.create_event(pub_event) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/api/events/#{pub_event.id}")
      |> render(:show, event: pub_event)
    end
  end

  swagger_path :show do
    get("/api/events/{event_id}")
    summary("Retrieve a Nostr event by ID")
    produces("application/json")
    tag("Events")
    operation_id("show_event")

    parameters do
      id(:path, :string, "Event ID", required: true)
    end

    response(200, "OK", Schema.ref(:PubEvent))
    response(404, "NotFound")
  end

  def show(conn, %{"id" => id}) do
    with {:ok, pub_event} <- Nostr.get_event(id) do
      render(conn, :show, event: pub_event)
    end
  end

  swagger_path :delete do
    PhoenixSwagger.Path.delete("/api/events/{event_id}")
    summary("Delete a Nostr event by ID")
    tag("Events")
    operation_id("delete_event")

    parameters do
      id(:path, :string, "Event ID", required: true)
    end

    response(204, "NoContent")
    response(404, "NotFound")
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, %PubEvent{} = pub_event} <- Nostr.get_event(id),
         {:ok, %Event{} = _} <- Nostr.delete_event(pub_event) do
      send_resp(conn, :no_content, "")
    end
  end

  def swagger_definitions do
    %{
      PubEvent:
        swagger_schema do
          title("PubEvent")
          description("A signed Nostr event")

          properties do
            id(:string, "32-byte lowercase hex event ID (SHA-256 of serialized event)",
              required: true
            )

            pubkey(:string, "32-byte lowercase hex public key of the event creator",
              required: true
            )

            created_at(:integer, "Unix timestamp in seconds", required: true)
            kind(:integer, "Nostr event kind", required: true)

            tags(
              %Schema{
                type: :array,
                items: %Schema{type: :array, items: %Schema{type: :string}}
              },
              "List of tags, each an array of strings",
              required: true
            )

            content(:string, "Arbitrary event content", required: true)
            sig(:string, "64-byte lowercase hex Schnorr signature", required: true)
          end

          example(%{
            id: "4376c65d2f232afbe9b882a35baa4f6fe8667c4e684749af565f981833ed6a65",
            pubkey: "6e468422dfb74a5738702a8823b9b28168abab8655faacb6853cd0ee15deee93",
            created_at: 1_673_347_337,
            kind: 1,
            tags: [],
            content: "Walled gardens became prisons, and users, lost.",
            sig:
              "908a15e46fb4d8675bab026fc230a0e3542bfade63da02d542fb78b2a8513fcd0092619a2c8c1221e581946e0191f2af505dfdf8657a414dbca329186f009262"
          })
        end,
      PubEventList:
        swagger_schema do
          title("PubEventList")
          description("A list of Nostr events")
          type(:array)
          items(Schema.ref(:PubEvent))
        end
    }
  end
end
