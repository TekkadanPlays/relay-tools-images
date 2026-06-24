defmodule GcIndexRelay.Nostr.PublicationContentSearch do
  @moduledoc """
  Full-text search over kind **30041** publication section body (`events.content`).

  Matches jumble's `scoreHaystackSearchQuery` / quoted phrase rules: quoted queries are phrase-only;
  unquoted queries match a contiguous phrase and/or require all significant words (length > 1).
  """

  import Ecto.Query, warn: false

  alias GcIndexRelay.Nostr.Event
  alias GcIndexRelay.Nostr.PubEvent
  alias GcIndexRelay.Nostr.PublicationSearch
  alias GcIndexRelay.Repo

  @publication_content_kind 30_041
  @min_substring_needle_len 2

  @doc """
  Search kind-30041 events by body text. Returns newest first.
  """
  @spec search(String.t(), keyword()) :: {:ok, [PubEvent.t()]} | {:error, String.t()}
  def search(query, opts \\ []) when is_binary(query) do
    trimmed = query |> strip_quotes() |> String.trim()

    if trimmed == "" do
      {:ok, []}
    else
      limit = opts |> Keyword.get(:limit, 25) |> clamp_limit()
      quoted = quoted?(query)
      needles = substring_needles(PublicationSearch.query_needles(trimmed))
      tokens = PublicationSearch.query_tokens(trimmed)
      content_match = content_match_dynamic(quoted, needles, tokens)
      do_search(content_match, limit)
    end
  end

  defp clamp_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(100)
  defp clamp_limit(_), do: 25

  defp do_search(content_match, limit) do
    events =
      from(e in Event,
        where: e.kind == ^@publication_content_kind,
        where: ^content_match,
        order_by: [desc: e.created_at],
        limit: ^limit,
        preload: [:tags]
      )
      |> Repo.all()

    pub_events_from_db(events)
  end

  defp content_match_dynamic(true, needles, _tokens) do
    phrase_content_match(needles)
  end

  defp content_match_dynamic(false, needles, tokens) do
    phrase = phrase_content_match(needles)
    multi = multi_word_content_match(tokens)

    dynamic([e], ^phrase or ^multi)
  end

  defp phrase_content_match([]), do: dynamic([e], false)

  defp phrase_content_match(needles) do
    Enum.reduce(needles, dynamic(false), fn needle, acc ->
      pattern = like_contains(needle)

      dynamic(
        [e],
        ^acc or fragment("LOWER(COALESCE(?, '')) LIKE ? ESCAPE '\\'", e.content, ^pattern)
      )
    end)
  end

  defp multi_word_content_match([]), do: dynamic([e], false)

  defp multi_word_content_match([_ | _] = tokens) when length(tokens) >= 2 do
    Enum.reduce(tokens, dynamic(true), fn token, acc ->
      pattern = like_contains(token)

      dynamic(
        [e],
        ^acc and fragment("LOWER(COALESCE(?, '')) LIKE ? ESCAPE '\\'", e.content, ^pattern)
      )
    end)
  end

  defp multi_word_content_match([token]), do: phrase_content_match([token])
  defp multi_word_content_match(_), do: dynamic([e], false)

  defp substring_needles(needles) do
    needles
    |> Enum.uniq()
    |> Enum.filter(&(String.length(&1) >= @min_substring_needle_len))
  end

  defp like_contains(value), do: "%#{like_escape(String.downcase(value))}%"

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

  defp quoted?(raw) do
    trimmed = String.trim(raw)

    pairs = [
      {"\"", "\""},
      {"'", "'"},
      {"“", "”"},
      {"‘", "’"}
    ]

    Enum.any?(pairs, fn {open, close} ->
      String.length(trimmed) >= 2 and String.starts_with?(trimmed, open) and
        String.ends_with?(trimmed, close)
    end)
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
end
