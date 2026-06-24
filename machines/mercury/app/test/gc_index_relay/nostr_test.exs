defmodule GcIndexRelay.NostrTest do
  use GcIndexRelay.DataCase

  import GcIndexRelay.NostrFixtures

  @moduletag :integration

  describe "reference kind 1111 event" do
    test "create_event and get_event round-trip all fields and tags" do
      event = reference_kind1111_pub_event()

      assert {:ok, _} = GcIndexRelay.Nostr.create_event(event)
      assert {:ok, loaded} = GcIndexRelay.Nostr.get_event(event.id)

      assert loaded.kind == event.kind
      assert loaded.content == event.content
      assert loaded.pubkey == event.pubkey
      assert loaded.created_at == event.created_at
      assert loaded.tags == event.tags
    end
  end
end
