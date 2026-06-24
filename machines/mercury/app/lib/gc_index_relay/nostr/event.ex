defmodule GcIndexRelay.Nostr.Event do
  @moduledoc """
  The database representation of a Nostr event.

  ## Associations

  Events have a 1..N association with `GcIndexRelay.Nostr.Tag`. Tags are stored on a separate
  table, but are always created and deleted in conjunction with their associated event.

  ## Notes

  Nostr's cryptographically-generated event IDs, since they are guaranteed to be unique, serve as
  the Event table's primary key. Event IDs and signatures are validated by a separate module, as
  the required cryptographic validations are not supported by Ecto.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias GcIndexRelay.Nostr.Tag

  @primary_key {:id, :binary, autogenerate: false}
  schema "events" do
    field :pubkey, :binary
    field :created_at, :utc_datetime
    field :kind, :integer
    field :content, :string
    field :sig, :binary
    has_many :tags, GcIndexRelay.Nostr.Tag, preload_order: [asc: :id]
  end

  @doc false
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:id, :pubkey, :created_at, :kind, :content, :sig])
    |> cast_assoc(:tags, with: &Tag.changeset/2)
    |> validate_required([:id, :pubkey, :created_at, :kind, :sig])
    |> validate_number(:kind, greater_than_or_equal_to: 0)
    |> validate_number(:kind, less_than: 40_000)
    |> unique_constraint(:id, name: :events_pkey)
  end
end
