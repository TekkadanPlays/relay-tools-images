defmodule GcIndexRelay.Nostr.PubEventTest do
  use ExUnit.Case, async: true

  alias GcIndexRelay.Nostr.Event
  alias GcIndexRelay.Nostr.PubEvent
  alias GcIndexRelay.Nostr.Tag

  import GcIndexRelay.NostrFixtures

  @moduletag :unit

  describe "to_db/1" do
    test "converts tags with name and value" do
      pub_event = valid_pub_event_fixture(tags: [["e", "abc123"], ["p", "def456"]])
      assert {:ok, event} = PubEvent.to_db(pub_event)

      assert [tag1, tag2] = event.tags
      assert %Tag{name: "e", value: "abc123", additional_values: []} = tag1
      assert %Tag{name: "p", value: "def456", additional_values: []} = tag2
    end

    test "converts tags with additional values" do
      tags = [["p", "pubkey_hex", "wss://relay.example.com", "alice"]]
      pub_event = valid_pub_event_fixture(tags: tags)
      assert {:ok, event} = PubEvent.to_db(pub_event)

      assert [tag] = event.tags
      assert %Tag{name: "p", value: "pubkey_hex"} = tag
      assert tag.additional_values == ["wss://relay.example.com", "alice"]
    end

    test "maps reference kind 1111 tags including uppercase names and extras" do
      pub_event = reference_kind1111_pub_event()
      assert {:ok, event} = PubEvent.to_db(pub_event)

      assert length(event.tags) == 7

      e_upper = Enum.find(event.tags, &(&1.name == "E"))
      assert e_upper.value == "6e35ec65661c5e2c453f9585a785b3f082c1daf9f769b3bb208af5459d178fca"

      assert e_upper.additional_values == [
               "wss://nostr.land/",
               "dd664d5e4016433a8cd69f005ae1480804351789b59de5af06276de65633d319"
             ]

      assert %Tag{name: "client", value: "imwald", additional_values: []} in event.tags
    end

    test "preserves empty content" do
      pub_event = valid_pub_event_fixture(content: "")
      assert {:ok, event} = PubEvent.to_db(pub_event)

      assert event.content == ""
    end
  end

  describe "from_db/1" do
    test "returns {:error, :not_found} for nil" do
      assert {:error, :not_found} = PubEvent.from_db(nil)
    end

    test "restores Nostr tag order from shuffled tag rows by database id" do
      event = %Event{
        id: Base.decode16!(String.duplicate("ab", 32), case: :lower),
        pubkey: Base.decode16!(String.duplicate("cd", 32), case: :lower),
        created_at: ~U[2021-12-20 17:46:40Z],
        kind: 30_040,
        content: "",
        sig: Base.decode16!(String.duplicate("ef", 64), case: :lower),
        tags: [
          %Tag{id: 300, name: "a", value: "chapter-2", additional_values: []},
          %Tag{id: 100, name: "d", value: "book", additional_values: []},
          %Tag{id: 200, name: "title", value: "Title", additional_values: []}
        ]
      }

      assert {:ok, pub_event} = PubEvent.from_db(event)
      assert pub_event.tags == [["d", "book"], ["title", "Title"], ["a", "chapter-2"]]
    end

    test "converts Tag structs back to nested lists" do
      event = %Event{
        id: Base.decode16!(String.duplicate("ab", 32), case: :lower),
        pubkey: Base.decode16!(String.duplicate("cd", 32), case: :lower),
        created_at: ~U[2021-12-20 17:46:40Z],
        kind: 1,
        content: "test",
        sig: Base.decode16!(String.duplicate("ef", 64), case: :lower),
        tags: [
          %Tag{name: "e", value: "event_id", additional_values: []},
          %Tag{name: "p", value: "pubkey", additional_values: ["relay", "petname"]}
        ]
      }

      assert {:ok, pub_event} = PubEvent.from_db(event)
      assert pub_event.tags == [["e", "event_id"], ["p", "pubkey", "relay", "petname"]]
    end

    test "preserves kind and content" do
      event = %Event{
        id: Base.decode16!(String.duplicate("ab", 32), case: :lower),
        pubkey: Base.decode16!(String.duplicate("cd", 32), case: :lower),
        created_at: ~U[2021-12-20 17:46:40Z],
        kind: 30_023,
        content: "long-form content",
        sig: Base.decode16!(String.duplicate("ef", 64), case: :lower),
        tags: []
      }

      assert {:ok, pub_event} = PubEvent.from_db(event)
      assert pub_event.kind == 30_023
      assert pub_event.content == "long-form content"
    end

    test "handles empty content" do
      event = %Event{
        id: Base.decode16!(String.duplicate("ab", 32), case: :lower),
        pubkey: Base.decode16!(String.duplicate("cd", 32), case: :lower),
        created_at: ~U[2021-12-20 17:46:40Z],
        kind: 1,
        content: "",
        sig: Base.decode16!(String.duplicate("ef", 64), case: :lower),
        tags: []
      }

      assert {:ok, pub_event} = PubEvent.from_db(event)
      assert pub_event.content == ""
    end
  end

  describe "round-trip: to_db |> from_db" do
    test "preserves all fields for a basic event" do
      pub_event = valid_pub_event_fixture(content: "round-trip test")

      assert {:ok, db} = PubEvent.to_db(pub_event)
      assert {:ok, result} = PubEvent.from_db(db)

      assert result.id == pub_event.id
      assert result.pubkey == pub_event.pubkey
      assert result.created_at == pub_event.created_at
      assert result.kind == pub_event.kind
      assert result.content == pub_event.content
      assert result.sig == pub_event.sig
      assert result.tags == pub_event.tags
    end

    test "preserves event with empty tags" do
      pub_event = valid_pub_event_fixture(tags: [])

      assert {:ok, db} = PubEvent.to_db(pub_event)
      assert {:ok, result} = PubEvent.from_db(db)
      assert result.tags == []
    end

    test "preserves event with tags" do
      tags = [
        ["e", "abc123"],
        ["p", "def456", "wss://relay.example.com"],
        ["t", "nostr", "extra1", "extra2"]
      ]

      pub_event = valid_pub_event_fixture(tags: tags)

      assert {:ok, db} = PubEvent.to_db(pub_event)
      assert {:ok, result} = PubEvent.from_db(db)
      assert result.tags == tags
    end

    test "preserves single-element tags (e.g. ['bot'])" do
      tags = [["bot"]]

      pub_event = valid_pub_event_fixture(tags: tags)

      assert {:ok, db} = PubEvent.to_db(pub_event)
      assert {:ok, result} = PubEvent.from_db(db)
      assert result.tags == tags
    end

    test "preserves mixed single-element and multi-element tags" do
      tags = [
        ["bot"],
        ["p", "def456"],
        ["content-warning"]
      ]

      pub_event = valid_pub_event_fixture(tags: tags)

      assert {:ok, db} = PubEvent.to_db(pub_event)
      assert {:ok, result} = PubEvent.from_db(db)
      assert result.tags == tags
    end

    test "preserves event with empty content" do
      pub_event = valid_pub_event_fixture(content: "")

      assert {:ok, db} = PubEvent.to_db(pub_event)
      assert {:ok, result} = PubEvent.from_db(db)
      assert result.content == ""
    end

    test "preserves different keypairs" do
      pub_event_1 = valid_pub_event_fixture(keypair: :keypair1)
      pub_event_2 = valid_pub_event_fixture(keypair: :keypair2)

      assert {:ok, db1} = PubEvent.to_db(pub_event_1)
      assert {:ok, db2} = PubEvent.to_db(pub_event_2)
      assert {:ok, result_1} = PubEvent.from_db(db1)
      assert {:ok, result_2} = PubEvent.from_db(db2)

      assert result_1.pubkey == pub_event_1.pubkey
      assert result_2.pubkey == pub_event_2.pubkey
      refute result_1.pubkey == result_2.pubkey
    end
  end

  describe "to_db/1 with invalid hex input" do
    test "returns error on invalid hex in id" do
      pub_event = valid_pub_event_fixture()
      invalid = %{pub_event | id: String.duplicate("zz", 32)}

      assert {:error, :invalid_hex} = PubEvent.to_db(invalid)
    end

    test "returns error on invalid hex in pubkey" do
      pub_event = valid_pub_event_fixture()
      invalid = %{pub_event | pubkey: String.duplicate("zz", 32)}

      assert {:error, :invalid_hex} = PubEvent.to_db(invalid)
    end

    test "returns error on invalid hex in sig" do
      pub_event = valid_pub_event_fixture()
      invalid = %{pub_event | sig: String.duplicate("zz", 64)}

      assert {:error, :invalid_hex} = PubEvent.to_db(invalid)
    end
  end
end
