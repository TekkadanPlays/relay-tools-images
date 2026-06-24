defmodule GcIndexRelay.Nostr.FilterTest do
  use ExUnit.Case, async: true
  alias GcIndexRelay.Nostr.Filter

  @moduletag :unit

  describe "from_map/1 with valid filters" do
    test "returns {:ok, filter} with valid ids" do
      valid_id = String.duplicate("a", 64)
      assert {:ok, filter} = Filter.from_map(%{"ids" => [valid_id]})
      assert filter.ids == [valid_id]
    end

    test "returns {:ok, filter} with valid authors" do
      valid_author = String.duplicate("b", 64)
      assert {:ok, filter} = Filter.from_map(%{"authors" => [valid_author]})
      assert filter.authors == [valid_author]
    end

    test "returns {:ok, filter} with valid kinds" do
      assert {:ok, filter} = Filter.from_map(%{"kinds" => [0, 1, 3]})
      assert filter.kinds == [0, 1, 3]
    end

    test "returns {:ok, filter} with valid tags (lowercase)" do
      assert {:ok, filter} = Filter.from_map(%{"#e" => ["value1", "value2"]})
      assert filter.tags == %{"e" => ["value1", "value2"]}
    end

    test "returns {:ok, filter} with valid tags (uppercase letter is distinct from lowercase)" do
      assert {:ok, filter} = Filter.from_map(%{"#E" => ["value1"]})
      assert filter.tags == %{"E" => ["value1"]}
    end

    test "returns {:ok, filter} with both #e and #E as separate tag filters" do
      assert {:ok, filter} =
               Filter.from_map(%{
                 "#e" => ["lowercase-scope"],
                 "#E" => ["uppercase-scope"],
                 "limit" => 10
               })

      assert filter.tags == %{"e" => ["lowercase-scope"], "E" => ["uppercase-scope"]}
    end

    test "returns {:ok, filter} with multiple valid tags" do
      assert {:ok, filter} = Filter.from_map(%{"#e" => ["val1"], "#p" => ["val2"]})
      assert filter.tags == %{"e" => ["val1"], "p" => ["val2"]}
    end

    test "returns {:ok, filter} with valid since" do
      assert {:ok, filter} = Filter.from_map(%{"since" => 1_640_000_000})
      assert filter.since == 1_640_000_000
    end

    test "returns {:ok, filter} with valid until" do
      assert {:ok, filter} = Filter.from_map(%{"until" => 1_640_000_000})
      assert filter.until == 1_640_000_000
    end

    test "returns {:ok, filter} with valid since and until" do
      assert {:ok, filter} = Filter.from_map(%{"since" => 1000, "until" => 2000})
      assert filter.since == 1000
      assert filter.until == 2000
    end

    test "returns {:ok, filter} with valid limit" do
      assert {:ok, filter} = Filter.from_map(%{"limit" => 10})
      assert filter.limit == 10
    end

    test "returns {:ok, filter} with all valid fields" do
      valid_id = String.duplicate("a", 64)
      valid_author = String.duplicate("b", 64)

      assert {:ok, filter} =
               Filter.from_map(%{
                 "ids" => [valid_id],
                 "authors" => [valid_author],
                 "kinds" => [0, 1],
                 "#e" => ["event1"],
                 "#p" => ["pubkey1"],
                 "since" => 1000,
                 "until" => 2000,
                 "limit" => 10
               })

      assert filter.ids == [valid_id]
      assert filter.authors == [valid_author]
      assert filter.kinds == [0, 1]
      assert filter.tags == %{"e" => ["event1"], "p" => ["pubkey1"]}
      assert filter.since == 1000
      assert filter.until == 2000
      assert filter.limit == 10
    end

    test "normalizes empty ids array to nil" do
      assert {:ok, filter} = Filter.from_map(%{"ids" => []})
      assert filter.ids == nil
    end

    test "normalizes empty authors array to nil" do
      assert {:ok, filter} = Filter.from_map(%{"authors" => []})
      assert filter.authors == nil
    end

    test "normalizes empty kinds array to nil" do
      assert {:ok, filter} = Filter.from_map(%{"kinds" => []})
      assert filter.kinds == nil
    end

    test "returns {:ok, filter} with since = 0" do
      assert {:ok, filter} = Filter.from_map(%{"since" => 0})
      assert filter.since == 0
    end

    test "returns {:ok, filter} with until = 0" do
      assert {:ok, filter} = Filter.from_map(%{"until" => 0})
      assert filter.until == 0
    end

    test "returns {:ok, filter} when since equals until" do
      assert {:ok, filter} = Filter.from_map(%{"since" => 1000, "until" => 1000})
      assert filter.since == 1000
      assert filter.until == 1000
    end
  end

  describe "from_map/1 with empty filter" do
    test "returns {:error, message} for completely empty map" do
      assert {:error, message} = Filter.from_map(%{})
      assert message =~ "Filter cannot be empty"
      assert message =~ "at least one filter field must be specified"
    end
  end

  describe "from_map/1 with invalid hex fields (ids/authors)" do
    @hex_field_test_cases [
      %{
        field: "ids",
        invalid_value_msg: "Invalid id in filter",
        array_type_msg: "Filter 'ids' must be an array of strings"
      },
      %{
        field: "authors",
        invalid_value_msg: "Invalid author in filter",
        array_type_msg: "Filter 'authors' must be an array of strings"
      }
    ]

    for %{field: field, invalid_value_msg: invalid_msg, array_type_msg: array_msg} <-
          @hex_field_test_cases do
      test "returns {:error, message} for short #{field}" do
        short_value = String.duplicate("a", 32)
        assert {:error, message} = Filter.from_map(%{unquote(field) => [short_value]})
        assert message =~ unquote(invalid_msg)
        assert message =~ "must be exactly 64 lowercase hex characters"
      end

      test "returns {:error, message} for long #{field}" do
        long_value = String.duplicate("a", 128)
        assert {:error, message} = Filter.from_map(%{unquote(field) => [long_value]})
        assert message =~ unquote(invalid_msg)
        assert message =~ "must be exactly 64 lowercase hex characters"
      end

      test "returns {:error, message} for uppercase hex #{field}" do
        uppercase_value = String.duplicate("A", 64)
        assert {:error, message} = Filter.from_map(%{unquote(field) => [uppercase_value]})
        assert message =~ unquote(invalid_msg)
        assert message =~ "must be exactly 64 lowercase hex characters"
      end

      test "returns {:error, message} for non-hex characters in #{field}" do
        invalid_value = String.duplicate("z", 64)
        assert {:error, message} = Filter.from_map(%{unquote(field) => [invalid_value]})
        assert message =~ unquote(invalid_msg)
        assert message =~ "must be exactly 64 lowercase hex characters"
      end

      test "returns {:error, message} for mixed valid and invalid #{field}" do
        valid_value = String.duplicate("a", 64)
        invalid_value = "short"

        assert {:error, message} =
                 Filter.from_map(%{unquote(field) => [valid_value, invalid_value]})

        assert message =~ unquote(invalid_msg)
      end

      test "returns {:error, message} for non-array #{field}" do
        assert {:error, message} = Filter.from_map(%{unquote(field) => "not-an-array"})
        assert message =~ unquote(array_msg)
      end

      test "returns {:error, message} for non-string in #{field} array" do
        assert {:error, message} = Filter.from_map(%{unquote(field) => [123]})
        assert message =~ unquote(invalid_msg)
      end
    end
  end

  describe "from_map/1 with invalid kinds" do
    test "returns {:error, message} for non-array kinds" do
      assert {:error, message} = Filter.from_map(%{"kinds" => "not-an-array"})
      assert message =~ "Filter 'kinds' must be an array of integers"
    end

    @invalid_kind_types [
      %{value: [1, "2", 3], desc: "non-integer string"},
      %{value: [1.5], desc: "float"},
      %{value: [nil], desc: "nil"}
    ]

    for %{value: value, desc: desc} <- @invalid_kind_types do
      test "returns {:error, message} for #{desc} in kinds array" do
        assert {:error, message} = Filter.from_map(%{"kinds" => unquote(Macro.escape(value))})
        assert message =~ "Invalid kind in filter"
        assert message =~ "must be an integer"
      end
    end

    @invalid_kind_ranges [
      %{value: -1, desc: "negative kind"},
      %{value: 40_000, desc: "kind >= 40000"},
      %{value: 50_000, desc: "kind > 40000"}
    ]

    for %{value: value, desc: desc} <- @invalid_kind_ranges do
      test "returns {:error, message} for #{desc}" do
        assert {:error, message} = Filter.from_map(%{"kinds" => [unquote(value)]})
        assert message =~ "Invalid kind in filter"
        assert message =~ "must be in the range [0, 40000)"
        assert message =~ "got #{unquote(value)}"
      end
    end
  end

  describe "from_map/1 with invalid tags" do
    @invalid_tag_keys [
      %{key: "#ee", desc: "multi-character"},
      %{key: "#1", desc: "numeric"},
      %{key: "#@", desc: "special character"}
    ]

    for %{key: key, desc: desc} <- @invalid_tag_keys do
      test "returns {:error, message} for #{desc} tag key" do
        assert {:error, message} = Filter.from_map(%{unquote(key) => ["value"]})
        assert message =~ "Invalid tag key '#{unquote(key)}'"
        assert message =~ "must be a single letter"
      end
    end

    test "returns {:error, message} for non-array tag value" do
      assert {:error, message} = Filter.from_map(%{"#e" => "not-an-array"})
      assert message =~ "Invalid tag value for '#e'"
      assert message =~ "must be an array of strings"
    end

    @invalid_tag_values [
      %{value: ["valid", 123], desc: "non-string"},
      %{value: [nil], desc: "nil"}
    ]

    for %{value: value, desc: desc} <- @invalid_tag_values do
      test "returns {:error, message} for #{desc} in tag value array" do
        assert {:error, message} = Filter.from_map(%{"#e" => unquote(Macro.escape(value))})
        assert message =~ "Invalid tag value for '#e'"
        assert message =~ "must be an array of strings"
      end
    end
  end

  describe "from_map/1 with invalid timestamps" do
    @timestamp_fields ["since", "until"]

    for field <- @timestamp_fields do
      test "returns {:error, message} for non-integer #{field}" do
        assert {:error, message} = Filter.from_map(%{unquote(field) => "not-an-integer"})
        assert message =~ "Filter '#{unquote(field)}' must be an integer"
      end

      test "returns {:error, message} for negative #{field}" do
        assert {:error, message} = Filter.from_map(%{unquote(field) => -1})
        assert message =~ "Filter '#{unquote(field)}' must be a non-negative integer"
        assert message =~ "got -1"
      end

      test "returns {:error, message} for float #{field}" do
        assert {:error, message} = Filter.from_map(%{unquote(field) => 1.5})
        assert message =~ "Filter '#{unquote(field)}' must be an integer"
      end
    end
  end

  describe "from_map/1 with invalid timestamp range" do
    test "returns {:error, message} when since > until" do
      assert {:error, message} = Filter.from_map(%{"since" => 2000, "until" => 1000})
      assert message =~ "Filter 'since' (2000) must be less than or equal to 'until' (1000)"
    end

    test "returns {:error, message} when since > until (large values)" do
      assert {:error, message} =
               Filter.from_map(%{"since" => 1_640_000_000, "until" => 1_630_000_000})

      assert message =~ "Filter 'since'"
      assert message =~ "must be less than or equal to"
      assert message =~ "until"
    end
  end

  describe "from_map/1 with invalid limit" do
    test "returns {:error, message} for non-integer limit" do
      assert {:error, message} = Filter.from_map(%{"limit" => "not-an-integer"})
      assert message =~ "Filter 'limit' must be an integer"
    end

    test "returns {:error, message} for float limit" do
      assert {:error, message} = Filter.from_map(%{"limit" => 10.5})
      assert message =~ "Filter 'limit' must be an integer"
    end

    @invalid_limit_values [
      %{value: 0, desc: "zero"},
      %{value: -5, desc: "negative"}
    ]

    for %{value: value, desc: desc} <- @invalid_limit_values do
      test "returns {:error, message} for #{desc} limit" do
        assert {:error, message} = Filter.from_map(%{"limit" => unquote(value)})
        assert message =~ "Filter 'limit' must be a positive integer"
        assert message =~ "got #{unquote(value)}"
      end
    end
  end

  describe "from_map/1 with unknown keys" do
    test "returns {:error, message} for literal 'tags' key" do
      assert {:error, message} = Filter.from_map(%{"tags" => ["value"]})
      assert message =~ "Unknown filter key"
      assert message =~ "tags"
    end

    test "returns {:error, message} for arbitrary unknown key" do
      assert {:error, message} = Filter.from_map(%{"random_key" => "value"})
      assert message =~ "Unknown filter key"
      assert message =~ "random_key"
    end

    test "returns {:error, message} for 'search' key" do
      assert {:error, message} = Filter.from_map(%{"search" => "text"})
      assert message =~ "Unknown filter key"
      assert message =~ "search"
    end

    test "returns {:error, message} even with valid fields present" do
      valid_id = String.duplicate("a", 64)

      assert {:error, message} =
               Filter.from_map(%{"ids" => [valid_id], "unknown" => "value"})

      assert message =~ "Unknown filter key"
      assert message =~ "unknown"
    end
  end
end
