defmodule GcIndexRelay.Nostr.HiddenEvent do
  @moduledoc """
  Ecto schema for hidden (soft-deleted) events.

  When a mod hides an event, it stays in the DB but is excluded
  from query results. This allows restoration without data loss.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:event_id, :string, autogenerate: false}
  schema "hidden_events" do
    field :hidden_by, :string
    field :community_atag, :string
    field :reason, :string
    field :hidden_at, :utc_datetime
  end

  @doc false
  def changeset(hidden, attrs) do
    hidden
    |> cast(attrs, [:event_id, :hidden_by, :community_atag, :reason, :hidden_at])
    |> validate_required([:event_id, :hidden_by])
    |> validate_format(:hidden_by, ~r/^[0-9a-f]{64}$/, message: "must be a 64-char hex pubkey")
    |> unique_constraint(:event_id, name: :hidden_events_pkey)
  end
end
