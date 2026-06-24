defmodule GcIndexRelay.Nostr.PubEvent do
  @moduledoc """
  The application domain model for a Nostr event.

  Refer to `GcIndexRelay.Nostr.Event` for the in-database representation of a Nostr event, and
  `GcIndexRelay.Nostr.Tag` for the in-database representation of a Nostr event tag.
  """

  alias GcIndexRelay.Nostr.Event
  alias GcIndexRelay.Nostr.Tag

  @derive Jason.Encoder
  defstruct [:id, :pubkey, :created_at, :kind, :tags, :content, :sig]

  @type t :: %__MODULE__{
          id: binary(),
          pubkey: binary(),
          created_at: integer(),
          kind: integer(),
          tags: [[String.t()]],
          content: String.t(),
          sig: binary()
        }

  @doc """
  Converts a `GcIndexRelay.Nostr.PubEvent` to its corresponding `GcIndexRelay.Nostr.Event` and
  `GcIndexRelay.Nostr.Tag` representations.
  """
  @spec to_db(t()) :: {:ok, Event.t()} | {:error, atom()}
  def to_db(%__MODULE__{} = pub_event) do
    tags = pub_event.tags || []

    with {:ok, event} <- to_event(pub_event) do
      {:ok, %{event | tags: to_tags(tags)}}
    end
  end

  @spec to_event(t()) :: {:ok, Event.t()} | {:error, atom()}
  defp to_event(%__MODULE__{} = pub_event) do
    with true <- pub_event_fields_valid?(pub_event),
         {:ok, id} <- Base.decode16(pub_event.id, case: :lower),
         {:ok, pubkey} <- Base.decode16(pub_event.pubkey, case: :lower),
         {:ok, signature} <- Base.decode16(pub_event.sig, case: :lower) do
      {:ok,
       %Event{
         id: id,
         pubkey: pubkey,
         created_at: DateTime.from_unix!(pub_event.created_at),
         kind: pub_event.kind,
         content: pub_event.content,
         sig: signature
       }}
    else
      false -> {:error, :invalid_event}
      :error -> {:error, :invalid_hex}
    end
  end

  defp pub_event_fields_valid?(%__MODULE__{} = p) do
    is_binary(p.id) and is_binary(p.pubkey) and is_integer(p.created_at) and is_integer(p.kind) and
      is_binary(p.sig) and is_list(p.tags || [])
  end

  @spec to_tags([[String.t()]]) :: [Ecto.Schema.t()]
  defp to_tags(tags) when is_list(tags) do
    for t <- tags do
      [name | values] = t

      {value, rest} =
        case values do
          [] -> {nil, []}
          [v | r] -> {v, r}
        end

      %Tag{
        name: name,
        value: value,
        additional_values: rest
      }
    end
  end

  @doc """
  Converts the DB representations of `GcIndexRelay.Nostr.Event` and `GcIndexRelay.Nostr.Tag` to the
  domain representation `GcIndexRelay.Nostr.PubEvent`.
  """
  @spec from_db(struct()) :: {:ok, t()} | {:error, :not_found}
  def from_db(event) when is_nil(event), do: {:error, :not_found}

  def from_db(%Event{tags: tags} = event) when is_struct(event, Event) and is_list(tags) do
    {:ok, %{from_event(event) | tags: from_tags(tags)}}
  end

  defp from_event(%Event{} = event) when is_struct(event, Event) do
    %__MODULE__{
      id: Base.encode16(event.id, case: :lower),
      pubkey: Base.encode16(event.pubkey, case: :lower),
      created_at: DateTime.to_unix(event.created_at),
      kind: event.kind,
      content: event.content,
      sig: Base.encode16(event.sig, case: :lower)
    }
  end

  defp from_tags(tags) when is_list(tags) do
    tags
    |> sort_tags_for_read()
    |> Enum.map(fn t ->
      case t.value do
        nil -> [t.name]
        value -> [t.name, value | t.additional_values]
      end
    end)
  end

  # Tag rows have no explicit position column; insertion id matches Nostr signing order.
  defp sort_tags_for_read(tags) do
    Enum.sort_by(tags, fn
      %Tag{id: id} when is_integer(id) -> {0, id}
      %Tag{} -> {1, 0}
    end)
  end
end
