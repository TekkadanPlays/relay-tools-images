defmodule GcIndexRelay.Nostr.PublicationSearch do
  @moduledoc """
  Metadata search over kind **30040** publication index tags (`d`, `title`, `author`, `source`).

  Matches jumble's publication metadata matching: case-insensitive, hyphen/space equivalence,
  substring matches for title/author/source (needle length ≥ 2), hyphen-segment matches on `d` tags,
  and multi-word AND when the query has two or more significant tokens.
  """

  import Ecto.Query, warn: false

  alias GcIndexRelay.Nostr.Event
  alias GcIndexRelay.Nostr.PubEvent
  alias GcIndexRelay.Nostr.Tag
  alias GcIndexRelay.Repo

  @publication_kind 30_040
  @search_tag_names ~w(d title author source)
  @min_substring_needle_len 2

  @doc """
  Search kind-30040 events by metadata match. Returns newest first.
  """
  @spec search(String.t(), keyword()) :: {:ok, [PubEvent.t()]} | {:error, String.t()}
  def search(query, opts \\ []) when is_binary(query) do
    trimmed = query |> strip_quotes() |> String.trim()

    if trimmed == "" do
      {:ok, []}
    else
      limit = opts |> Keyword.get(:limit, 25) |> clamp_limit()
      needles = query_needles(trimmed)
      tokens = query_tokens(trimmed)
      do_search(needles, tokens, limit)
    end
  end

  defp clamp_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(100)
  defp clamp_limit(_), do: 25

  defp do_search(needles, tokens, limit) do
    tag_match = metadata_tag_match(needles, tokens)

    events =
      from(e in Event,
        as: :event,
        where: e.kind == ^@publication_kind,
        where:
          exists(
            from(t in Tag,
              where: t.event_id == parent_as(:event).id,
              where: t.name in ^@search_tag_names,
              where: not is_nil(t.value),
              where: ^tag_match
            )
          ),
        order_by: [desc: e.created_at],
        limit: ^limit,
        preload: [:tags]
      )
      |> Repo.all()

    pub_events_from_db(events)
  end

  defp metadata_tag_match(needles, tokens) do
    spaced_needles = Enum.map(needles, &spaced_form/1) |> Enum.uniq()

    exact =
      Enum.reduce(needles, dynamic(false), fn needle, acc ->
        spaced = spaced_form(needle)

        dynamic(
          [t],
          ^acc or
            fragment("LOWER(TRIM(?)) = ?", t.value, ^needle) or
            fragment("LOWER(TRIM(REPLACE(?, '-', ' '))) = ?", t.value, ^spaced)
        )
      end)

    exact =
      Enum.reduce(spaced_needles, exact, fn spaced, acc ->
        dynamic(
          [t],
          ^acc or fragment("LOWER(TRIM(REPLACE(?, '-', ' '))) = ?", t.value, ^spaced)
        )
      end)

    substring =
      Enum.reduce(substring_needles(needles), dynamic(false), fn needle, acc ->
        spaced = spaced_form(needle)
        pattern = like_contains(spaced)

        dynamic(
          [t],
          ^acc or
            fragment(
              "LOWER(TRIM(REPLACE(?, '-', ' '))) LIKE ? ESCAPE '\\'",
              t.value,
              ^pattern
            )
        )
      end)

    d_segment =
      Enum.reduce(d_segment_needles(needles), dynamic(false), fn needle, acc ->
        dynamic([t], ^acc or ^d_tag_segment_match(needle))
      end)

    multi_word =
      case tokens do
        [_ | _] = word_tokens when length(word_tokens) >= 2 ->
          Enum.reduce(word_tokens, dynamic(true), fn token, acc ->
            pattern = like_contains(spaced_form(token))

            dynamic(
              [t],
              ^acc and
                fragment(
                  "LOWER(TRIM(REPLACE(?, '-', ' '))) LIKE ? ESCAPE '\\'",
                  t.value,
                  ^pattern
                )
            )
          end)

        _ ->
          dynamic(false)
      end

    dynamic([t], ^exact or ^substring or ^d_segment or ^multi_word)
  end

  defp substring_needles(needles) do
    needles
    |> Enum.uniq()
    |> Enum.filter(&(String.length(&1) >= @min_substring_needle_len))
  end

  defp d_segment_needles(needles) do
    needles
    |> Enum.flat_map(fn needle ->
      spaced = spaced_form(needle)
      hyphen = needle |> String.replace(~r/\s+/, "-") |> String.replace(~r/-+/, "-") |> String.trim("-")
      [needle, spaced, hyphen]
    end)
    |> Enum.uniq()
    |> Enum.filter(&(String.length(&1) >= @min_substring_needle_len))
  end

  defp d_tag_segment_match(needle) do
    dynamic(
      [t],
      t.name == "d" and
        (fragment("LOWER(TRIM(?)) = ?", t.value, ^needle) or
           fragment("LOWER(TRIM(?)) LIKE ? ESCAPE '\\'", t.value, ^like_prefix(needle)) or
           fragment("LOWER(TRIM(?)) LIKE ? ESCAPE '\\'", t.value, ^like_segment(needle)) or
           fragment("LOWER(TRIM(?)) LIKE ? ESCAPE '\\'", t.value, ^like_suffix(needle)))
    )
  end

  defp like_contains(value), do: "%#{like_escape(value)}%"
  defp like_prefix(value), do: "#{like_escape(value)}-%"
  defp like_segment(value), do: "%-#{like_escape(value)}-%"
  defp like_suffix(value), do: "%-#{like_escape(value)}"

  defp like_escape(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp pub_events_from_db(events) do
    Enum.reduce_while(events, {:ok, []}, fn event, {:ok, acc} ->
      case PubEvent.from_db(event) do
        {:ok, pub_event} -> {:cont, {:ok, [pub_event | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      {:error, _} = err -> err
    end
  end

  @doc false
  def query_needles(query) do
    query
    |> strip_quotes()
    |> String.trim()
    |> case do
      "" ->
        []

      raw ->
        lower = String.downcase(raw)
        normalized = lower |> String.replace(~r/\s+/, " ") |> String.trim()

        hyphen =
          lower
          |> String.replace(~r/\s+/, "-")
          |> String.replace(~r/-+/, "-")
          |> String.trim("-")

        [lower, normalized, hyphen]
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()
    end
  end

  @doc false
  def query_tokens(query) do
    query
    |> strip_quotes()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/\s+/, " ")
    |> String.split(" ", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&(String.length(&1) > 1))
    |> Enum.uniq()
  end

  defp strip_quotes(raw) do
    trimmed = String.trim(raw)

    pairs = [
      {"\"", "\""},
      {"'", "'"},
      {"“", "”"},
      {"‘", "’"}
    ]

    Enum.reduce(pairs, trimmed, fn {open, close}, acc ->
      if String.length(acc) >= 2 and String.starts_with?(acc, open) and
           String.ends_with?(acc, close) do
        acc |> String.slice(1..-2//1) |> String.trim()
      else
        acc
      end
    end)
  end

  defp spaced_form(value) do
    value
    |> String.downcase()
    |> String.replace("-", " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
