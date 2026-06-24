defmodule GcIndexRelay.Nostr.PublicationContentSearchTest do
  use GcIndexRelay.DataCase

  import GcIndexRelay.NostrFixtures

  alias GcIndexRelay.Nostr
  alias GcIndexRelay.Nostr.PublicationContentSearch
  alias GcIndexRelay.Nostr.Validator

  @moduletag :integration

  defp insert_content!(d, body, created_at \\ nil) do
    attrs = %{
      kind: 30_041,
      content: body,
      tags: [["d", d]]
    }

    attrs = if created_at, do: Map.put(attrs, :created_at, created_at), else: attrs

    event = valid_pub_event_fixture(attrs)
    assert {:ok, _} = Nostr.create_event(event)
    event
  end

  test "search finds phrase in section body" do
    insert_content!(
      "pg1342-ch-1",
      "It is a truth universally acknowledged, that a single man in possession of a good fortune.",
      1_700_000_100
    )

    insert_content!("other-ch-1", "Completely different text.", 1_700_000_200)

    assert {:ok, results} =
             PublicationContentSearch.search("truth universally acknowledged", limit: 10)

    assert length(results) == 1
    assert hd(results).kind == 30_041
    assert Enum.any?(hd(results).tags, fn ["d", v] -> v == "pg1342-ch-1" end)
  end

  test "quoted search is phrase-only" do
    insert_content!("pg1342-ch-1", "truth universally acknowledged by everyone")

    assert {:ok, results} = PublicationContentSearch.search("\"truth acknowledged\"", limit: 10)
    assert results == []
  end

  test "search returns signature-valid events" do
    insert_content!("pg1342-ch-1", "truth universally acknowledged")

    assert {:ok, [result | _]} = PublicationContentSearch.search("truth universally", limit: 10)
    assert {:ok, ^result} = Validator.validate_signature(result)
    assert {:ok, ^result} = Validator.validate_id(result)
  end
end
