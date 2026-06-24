defmodule GcIndexRelay.NostrEphemeralTest do
  use GcIndexRelay.DataCase, async: false

  alias GcIndexRelay.Nostr
  alias GcIndexRelay.Nostr.PubEvent
  import GcIndexRelay.NostrFixtures

  @moduletag :integration

  setup do
    Phoenix.PubSub.subscribe(GcIndexRelay.PubSub, "events")
    :ok
  end

  describe "ephemeral events (NIP-47)" do
    test "kind 23194 is broadcast but not saved to the database" do
      ephemeral_event = valid_pub_event_fixture(kind: 23194)

      # Attempt to create the event
      assert {:ok, _} = Nostr.create_event(ephemeral_event)

      # It should not be saved in the database
      assert Nostr.get_event(ephemeral_event.id) == {:error, :not_found}

      # But it MUST be broadcast to active subscribers
      assert_receive {:new_event, ^ephemeral_event}, 500
    end

    test "regular events are saved and broadcast" do
      regular_event = valid_pub_event_fixture(kind: 1)

      assert {:ok, _} = Nostr.create_event(regular_event)

      # It should be saved
      assert {:ok, _db_event} = Nostr.get_event(regular_event.id)

      # It should be broadcast
      assert_receive {:new_event, ^regular_event}, 500
    end
  end
end
