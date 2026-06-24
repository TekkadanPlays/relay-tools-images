defmodule GcIndexRelay.Nostr.Filter do
  @moduledoc """
  Nostr NIP-01 filters: struct, parsing, validation, and query building.

  Single-letter tag filter keys (`#p`, `#P`, `#e`, `#E`, …) are **case-sensitive**: uppercase and
  lowercase names refer to different tags (e.g. NIP-22 uses `P`/`p`, `E`/`e`, `K`/`k` for distinct
  semantics). Do not fold case when matching stored tag names.
  """

  alias GcIndexRelay.Nostr.Event
  alias GcIndexRelay.Repo
  alias GcIndexRelay.Nostr.Tag
  alias GcIndexRelay.Nostr.Validator
  import Ecto.Query

  defstruct [:ids, :authors, :kinds, :tags, :since, :until, :limit]

  @type t :: %__MODULE__{
          ids: [String.t()] | nil,
          authors: [String.t()] | nil,
          kinds: [integer()] | nil,
          tags: %{String.t() => [String.t()]} | nil,
          since: integer() | nil,
          until: integer() | nil,
          limit: pos_integer() | nil
        }

  @spec from_map(map()) :: {:ok, t()} | {:error, String.t()}
  def from_map(map) when is_map(map) do
    # Keys `#p` and `#P` (and likewise for every letter) are distinct filters; preserve case.
    tags =
      for {"#" <> k, v} <- map,
          String.length(k) == 1,
          String.match?(k, ~r/^[a-zA-Z]$/),
          do: {k, v},
          into: %{}

    # Validate only known keys are present
    with :ok <- validate_not_empty(map),
         :ok <- validate_known_keys(map),
         {:ok, ids} <- validate_ids(map["ids"]),
         {:ok, authors} <- validate_authors(map["authors"]),
         {:ok, kinds} <- validate_kinds(map["kinds"]),
         {:ok, validated_tags} <- validate_tags(tags),
         {:ok, since} <- validate_timestamp(map["since"], :since),
         {:ok, until} <- validate_timestamp(map["until"], :until),
         {:ok, _} <- validate_timestamp_range(map["since"], map["until"]),
         {:ok, limit} <- validate_limit(map["limit"]) do
      {:ok,
       %__MODULE__{
         ids: ids,
         authors: authors,
         kinds: kinds,
         tags: validated_tags,
         since: since,
         until: until,
         limit: limit
       }}
    end
  end

  # Validate that filter is not empty
  @spec validate_not_empty(map()) :: :ok | {:error, String.t()}
  defp validate_not_empty(map) when map_size(map) == 0 do
    {:error, "Filter cannot be empty - at least one filter field must be specified"}
  end

  defp validate_not_empty(_map), do: :ok

  # Validate that only known filter keys are present. `#` keys must be exactly `#` + one letter.
  @spec validate_known_keys(map()) :: :ok | {:error, String.t()}
  defp validate_known_keys(map) do
    known_keys = ["ids", "authors", "kinds", "since", "until", "limit"]

    case Enum.find(Map.keys(map), &invalid_filter_map_key?(&1, known_keys)) do
      nil -> :ok
      <<"#", _::binary>> = key -> {:error, invalid_hash_filter_key_message(key)}
      key -> {:error, "Unknown filter key: '#{key}'"}
    end
  end

  defp invalid_filter_map_key?(key, known_keys) do
    cond do
      key in known_keys -> false
      valid_tag_filter_key?(key) -> false
      true -> true
    end
  end

  defp valid_tag_filter_key?(<<"#", letter::binary-size(1)>>) do
    String.match?(letter, ~r/^[a-zA-Z]$/)
  end

  defp valid_tag_filter_key?(_), do: false

  defp invalid_hash_filter_key_message(key) do
    "Invalid tag key '#{key}': must be a single letter (a-z, A-Z)"
  end

  @spec validate_ids([String.t()] | nil) :: {:ok, [String.t()] | nil} | {:error, String.t()}
  defp validate_ids(nil), do: {:ok, nil}
  defp validate_ids([]), do: {:ok, nil}

  defp validate_ids(ids) when is_list(ids) do
    if Enum.all?(ids, &Validator.valid_hex_id?/1) do
      {:ok, ids}
    else
      invalid = Enum.find(ids, &(!Validator.valid_hex_id?(&1)))
      {:error, "Invalid id in filter: '#{invalid}' must be exactly 64 lowercase hex characters"}
    end
  end

  defp validate_ids(_), do: {:error, "Filter 'ids' must be an array of strings"}

  @spec validate_authors([String.t()] | nil) :: {:ok, [String.t()] | nil} | {:error, String.t()}
  defp validate_authors(nil), do: {:ok, nil}
  defp validate_authors([]), do: {:ok, nil}

  defp validate_authors(authors) when is_list(authors) do
    if Enum.all?(authors, &Validator.valid_hex_id?/1) do
      {:ok, authors}
    else
      invalid = Enum.find(authors, &(!Validator.valid_hex_id?(&1)))

      {:error,
       "Invalid author in filter: '#{invalid}' must be exactly 64 lowercase hex characters"}
    end
  end

  defp validate_authors(_), do: {:error, "Filter 'authors' must be an array of strings"}

  @spec validate_kinds([integer()] | nil) :: {:ok, [integer()] | nil} | {:error, String.t()}
  defp validate_kinds(nil), do: {:ok, nil}
  defp validate_kinds([]), do: {:ok, nil}

  defp validate_kinds(kinds) when is_list(kinds) do
    cond do
      !Enum.all?(kinds, &is_integer/1) ->
        invalid = Enum.find(kinds, &(!is_integer(&1)))
        {:error, "Invalid kind in filter: '#{inspect(invalid)}' must be an integer"}

      !Enum.all?(kinds, &(&1 >= 0 and &1 < 40_000)) ->
        invalid = Enum.find(kinds, &(&1 < 0 or &1 >= 40_000))

        {:error,
         "Invalid kind in filter: '#{invalid}' must be in the range [0, 40000), got #{invalid}"}

      true ->
        {:ok, kinds}
    end
  end

  defp validate_kinds(_), do: {:error, "Filter 'kinds' must be an array of integers"}

  @spec validate_tags(map()) :: {:ok, map() | nil} | {:error, String.t()}
  defp validate_tags(tags) when map_size(tags) == 0, do: {:ok, nil}

  defp validate_tags(tags) when is_map(tags) do
    with :ok <- validate_tag_keys(tags),
         :ok <- validate_tag_values(tags) do
      {:ok, tags}
    end
  end

  @spec validate_tag_keys(map()) :: :ok | {:error, String.t()}
  defp validate_tag_keys(tags) do
    # Inline validation logic for better locality of behavior
    invalid_key =
      tags
      |> Map.keys()
      |> Enum.find(fn k ->
        !is_binary(k) or String.length(k) != 1 or !String.match?(k, ~r/^[a-zA-Z]$/)
      end)

    case invalid_key do
      nil -> :ok
      key -> {:error, "Invalid tag key '##{key}': must be a single letter (a-z, A-Z)"}
    end
  end

  @spec validate_tag_values(map()) :: :ok | {:error, String.t()}
  defp validate_tag_values(tags) do
    invalid_entry =
      Enum.find(tags, fn {_k, v} ->
        !is_list(v) or !Enum.all?(v, &is_binary/1)
      end)

    case invalid_entry do
      nil ->
        :ok

      {key, value} ->
        {:error,
         "Invalid tag value for '##{key}': '#{inspect(value)}' must be an array of strings"}
    end
  end

  @spec validate_timestamp(integer() | nil, atom()) ::
          {:ok, integer() | nil} | {:error, String.t()}
  defp validate_timestamp(nil, _field), do: {:ok, nil}

  defp validate_timestamp(ts, _field) when is_integer(ts) and ts >= 0 do
    {:ok, ts}
  end

  defp validate_timestamp(ts, field) when is_integer(ts) do
    {:error, "Filter '#{field}' must be a non-negative integer, got #{ts}"}
  end

  defp validate_timestamp(ts, field) do
    {:error, "Filter '#{field}' must be an integer, got #{inspect(ts)}"}
  end

  @spec validate_timestamp_range(integer() | nil, integer() | nil) ::
          {:ok, :valid} | {:error, String.t()}
  defp validate_timestamp_range(nil, _until), do: {:ok, :valid}
  defp validate_timestamp_range(_since, nil), do: {:ok, :valid}

  defp validate_timestamp_range(since, until) when since <= until do
    {:ok, :valid}
  end

  defp validate_timestamp_range(since, until) do
    {:error, "Filter 'since' (#{since}) must be less than or equal to 'until' (#{until})"}
  end

  @spec validate_limit(pos_integer() | nil) :: {:ok, pos_integer() | nil} | {:error, String.t()}
  defp validate_limit(nil), do: {:ok, nil}

  defp validate_limit(limit) when is_integer(limit) and limit > 0 do
    {:ok, limit}
  end

  defp validate_limit(limit) when is_integer(limit) do
    {:error, "Filter 'limit' must be a positive integer, got #{limit}"}
  end

  defp validate_limit(limit) do
    {:error, "Filter 'limit' must be an integer, got #{inspect(limit)}"}
  end

  @doc """
  Applies a filter to an Ecto query of Nostr events.

  ## Params

  - `query` - An Ecto query. This MUST be a query over the `GcIndexRelay.Nostr.Event` schema.
  - `filter` - A `GcIndexRelay.Nostr.Filter` struct.

  ## Returns

  A filtered list of events in descending order of creation time.
  """
  @spec apply(Ecto.Query.t(), t()) :: [struct()]
  def apply(%Ecto.Query{from: %{source: {_table, Event}}} = query, %__MODULE__{} = filter) do
    query
    |> apply_ids(filter.ids)
    |> apply_authors(filter.authors)
    |> apply_kinds(filter.kinds)
    |> apply_since(filter.since)
    |> apply_until(filter.until)
    |> preload(:tags)
    |> apply_tags(filter.tags)
    # Always sort in descending order of creation time
    |> order_by([e], desc: e.created_at)
    |> apply_limit(filter.limit)
    |> Repo.all()
  end

  @spec apply_ids(Ecto.Query.t(), [String.t()] | nil) :: Ecto.Query.t()
  defp apply_ids(query, nil), do: query
  defp apply_ids(query, []), do: query

  defp apply_ids(query, ids) do
    binary_ids = Enum.map(ids, &Base.decode16!(&1, case: :lower))
    where(query, [e], e.id in ^binary_ids)
  end

  @spec apply_authors(Ecto.Query.t(), [String.t()] | nil) :: Ecto.Query.t()
  defp apply_authors(query, nil), do: query
  defp apply_authors(query, []), do: query

  defp apply_authors(query, authors) do
    binary_authors = Enum.map(authors, &Base.decode16!(&1, case: :lower))
    where(query, [e], e.pubkey in ^binary_authors)
  end

  @spec apply_kinds(Ecto.Query.t(), [integer()] | nil) :: Ecto.Query.t()
  defp apply_kinds(query, nil), do: query
  defp apply_kinds(query, []), do: query
  defp apply_kinds(query, kinds), do: where(query, [e], e.kind in ^kinds)

  @spec apply_since(Ecto.Query.t(), integer() | nil) :: Ecto.Query.t()
  defp apply_since(query, nil), do: query

  defp apply_since(query, since) when is_integer(since) do
    datetime = DateTime.from_unix!(since)
    where(query, [e], e.created_at >= ^datetime)
  end

  @spec apply_until(Ecto.Query.t(), integer() | nil) :: Ecto.Query.t()
  defp apply_until(query, nil), do: query

  defp apply_until(query, until) when is_integer(until) do
    datetime = DateTime.from_unix!(until)
    where(query, [e], e.created_at <= ^datetime)
  end

  @spec apply_tags(Ecto.Query.t(), map() | nil) :: Ecto.Query.t()
  defp apply_tags(query, nil), do: query
  defp apply_tags(query, tags) when map_size(tags) == 0, do: query

  defp apply_tags(query, tags) do
    query = from(e in query, as: :event_query)

    Enum.reduce(tags, query, fn {tag_name, tag_values}, acc_query ->
      where(
        acc_query,
        [e],
        exists(
          from t in Tag,
            where: t.event_id == parent_as(:event_query).id,
            where: t.name == ^tag_name,
            where: t.value in ^tag_values
        )
      )
    end)
  end

  @spec apply_limit(Ecto.Query.t(), pos_integer() | nil) :: Ecto.Query.t()
  defp apply_limit(query, nil), do: query
  defp apply_limit(query, limit), do: limit(query, ^limit)
end

defimpl Jason.Encoder, for: GcIndexRelay.Nostr.Filter do
  alias GcIndexRelay.Nostr.Filter

  def encode(%Filter{} = filter, opts) do
    # Prefix single-letter tags with '#'
    tags_map =
      case filter.tags do
        nil -> %{}
        tags -> Enum.map(tags, fn {k, v} -> {"#" <> k, v} end) |> Map.new()
      end

    # Produce a map from the remaining filter fields
    rest_map =
      filter
      |> Map.from_struct()
      |> Map.delete(:tags)

    # Merge the tags into the remaining fields and encode with Jason
    Map.merge(rest_map, tags_map)
    |> Jason.Encode.map(opts)
  end
end
