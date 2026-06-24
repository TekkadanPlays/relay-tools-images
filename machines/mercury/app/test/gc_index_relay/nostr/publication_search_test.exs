defmodule GcIndexRelay.Nostr.PublicationSearchTest do
  use GcIndexRelay.DataCase

  import GcIndexRelay.NostrFixtures

  alias GcIndexRelay.Nostr
  alias GcIndexRelay.Nostr.PublicationSearch
  alias GcIndexRelay.Nostr.Validator

  @moduletag :integration

  defp insert_publication!(d, title, author, source, created_at \\ nil) do
    attrs = %{
      kind: 30_040,
      content: "",
      tags: [
        ["d", d],
        ["title", title],
        ["author", author],
        ["source", source]
      ]
    }

    attrs = if created_at, do: Map.put(attrs, :created_at, created_at), else: attrs

    event = valid_pub_event_fixture(attrs)
    assert {:ok, _} = Nostr.create_event(event)
    event
  end

  test "search finds exact title match" do
    insert_publication!(
      "pg1342-pride-and-prejudice",
      "Pride and Prejudice",
      "Jane Austen",
      "https://www.gutenberg.org/ebooks/1342",
      1_700_000_100
    )

    insert_publication!(
      "other-book",
      "Other Book",
      "Someone",
      "https://example.com/1",
      1_700_000_200
    )

    assert {:ok, results} = PublicationSearch.search("pride and prejudice", limit: 10)
    assert length(results) == 1
    assert hd(results).kind == 30_040
    assert Enum.any?(hd(results).tags, fn ["d", v] -> v == "pg1342-pride-and-prejudice" end)
  end

  test "search finds exact d-tag match" do
    insert_publication!(
      "pg1342-pride-and-prejudice",
      "Pride and Prejudice",
      "Jane Austen",
      "https://www.gutenberg.org/ebooks/1342"
    )

    assert {:ok, results} = PublicationSearch.search("pg1342-pride-and-prejudice", limit: 10)
    assert length(results) == 1
  end

  test "search returns signature-valid events" do
    insert_publication!(
      "pg1342-pride-and-prejudice",
      "Pride and Prejudice",
      "Jane Austen",
      "https://www.gutenberg.org/ebooks/1342"
    )

    assert {:ok, [result | _]} = PublicationSearch.search("pride and prejudice", limit: 10)
    assert {:ok, ^result} = Validator.validate_signature(result)
    assert {:ok, ^result} = Validator.validate_id(result)
  end

  test "search finds partial d-tag and title needles" do
    insert_publication!(
      "pg1342-pride-and-prejudice",
      "Pride and Prejudice",
      "Jane Austen",
      "https://www.gutenberg.org/ebooks/1342"
    )

    assert {:ok, results} = PublicationSearch.search("pg1342", limit: 10)
    assert length(results) == 1

    assert {:ok, results} = PublicationSearch.search("pride-and", limit: 10)
    assert length(results) == 1

    assert {:ok, results} = PublicationSearch.search("prejudice", limit: 10)
    assert length(results) == 1

    assert {:ok, results} = PublicationSearch.search("jane austen", limit: 10)
    assert length(results) == 1
  end

  test "search rejects single-character needles" do
    insert_publication!(
      "pg1342-pride-and-prejudice",
      "Pride and Prejudice",
      "Jane Austen",
      "https://www.gutenberg.org/ebooks/1342"
    )

    assert {:ok, []} = PublicationSearch.search("p", limit: 10)
  end
end
