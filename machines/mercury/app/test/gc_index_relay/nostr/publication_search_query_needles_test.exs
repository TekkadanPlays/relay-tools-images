defmodule GcIndexRelay.Nostr.PublicationSearchQueryNeedlesTest do
  use ExUnit.Case, async: true

  alias GcIndexRelay.Nostr.PublicationSearch

  @moduletag :unit

  test "query_needles returns empty list for blank input" do
    assert PublicationSearch.query_needles("") == []
    assert PublicationSearch.query_needles("   ") == []
  end

  test "query_needles normalizes case, spaces, and hyphens" do
    assert PublicationSearch.query_needles("Pride and Prejudice") == [
             "pride and prejudice",
             "pride-and-prejudice"
           ]
  end

  test "query_needles strips surrounding quotes" do
    assert PublicationSearch.query_needles(~s("Jane Eyre")) == ["jane eyre", "jane-eyre"]
    assert PublicationSearch.query_needles("'Jane Eyre'") == ["jane eyre", "jane-eyre"]
  end

  test "query_needles collapses repeated whitespace and hyphens" do
    assert PublicationSearch.query_needles("pride   and   prejudice") == [
             "pride   and   prejudice",
             "pride and prejudice",
             "pride-and-prejudice"
           ]

    assert PublicationSearch.query_needles("pg1342--pride--and--prejudice") == [
             "pg1342--pride--and--prejudice",
             "pg1342-pride-and-prejudice"
           ]
  end
end
