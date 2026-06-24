defmodule GcIndexRelay.Nostr.ModerationTest do
  use GcIndexRelay.DataCase, async: true

  alias GcIndexRelay.Nostr.Moderation
  alias GcIndexRelay.Nostr.PubEvent
  alias GcIndexRelay.Repo
  alias GcIndexRelay.Nostr.Event
  import GcIndexRelay.NostrFixtures

  @moduletag :integration

  describe "validate_community_access/1" do
    test "allows event without community tag" do
      event = valid_pub_event_fixture()
      assert {:ok, ^event} = Moderation.validate_community_access(event)
    end

    test "allows event with community tag if user is not banned" do
      admin_pubkey = String.duplicate("aa", 32)
      author_pubkey = String.duplicate("bb", 32)
      
      event = valid_pub_event_fixture(
        pubkey: author_pubkey,
        tags: [["a", "34550:#{admin_pubkey}:my_community"]]
      )

      assert {:ok, ^event} = Moderation.validate_community_access(event)
    end

    test "rejects event if user is banned from the community" do
      admin_pubkey = String.duplicate("aa", 32)
      author_pubkey = String.duplicate("bb", 32)
      
      # Create mute list event (kind 30000) by admin banning author
      mute_list = valid_pub_event_fixture(
        pubkey: admin_pubkey,
        kind: 30000,
        tags: [["p", author_pubkey]]
      )
      
      # Insert into db directly to bypass create_event pipeline (which might fail sig check)
      {:ok, db_event} = PubEvent.to_db(mute_list)
      tags_as_maps = Enum.map(db_event.tags, &Map.from_struct/1)
      attrs = db_event |> Map.from_struct() |> Map.put(:tags, tags_as_maps)
      %Event{} |> Event.changeset(attrs) |> Repo.insert!()

      event = valid_pub_event_fixture(
        pubkey: author_pubkey,
        tags: [["a", "34550:#{admin_pubkey}:my_community"]]
      )

      assert {:error, "blocked: user is banned from this community"} = 
               Moderation.validate_community_access(event)
    end
  end

  describe "authorize_admin_deletion?/2" do
    test "returns false if target event has no community tag" do
      deletion_event = valid_pub_event_fixture(pubkey: String.duplicate("aa", 32))
      target_event = valid_pub_event_fixture(tags: [])

      refute Moderation.authorize_admin_deletion?(deletion_event, target_event)
    end

    test "returns true if deletion is signed by community admin" do
      admin_pubkey = String.duplicate("aa", 32)
      deletion_event = valid_pub_event_fixture(pubkey: admin_pubkey)
      target_event = valid_pub_event_fixture(
        tags: [["a", "34550:#{admin_pubkey}:my_community"]]
      )

      assert Moderation.authorize_admin_deletion?(deletion_event, target_event)
    end

    test "returns false if deletion is not signed by community admin" do
      admin_pubkey = String.duplicate("aa", 32)
      other_pubkey = String.duplicate("cc", 32)
      
      deletion_event = valid_pub_event_fixture(pubkey: other_pubkey)
      target_event = valid_pub_event_fixture(
        tags: [["a", "34550:#{admin_pubkey}:my_community"]]
      )

      refute Moderation.authorize_admin_deletion?(deletion_event, target_event)
    end
  end
end
