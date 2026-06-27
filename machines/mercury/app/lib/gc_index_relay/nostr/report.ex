defmodule GcIndexRelay.Nostr.Report do
  @moduledoc """
  Ecto schema for event reports.

  Users can report events for review. Community mods see reports
  for their communities; site admins see all reports.

  Status lifecycle: pending → approved | dismissed
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "reports" do
    field :event_id, :string
    field :reporter_pubkey, :string
    field :community_atag, :string
    field :reason, :string
    field :status, :string, default: "pending"
    field :resolved_by, :string
    field :resolved_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(report, attrs) do
    report
    |> cast(attrs, [:event_id, :reporter_pubkey, :community_atag, :reason, :status, :resolved_by, :resolved_at])
    |> validate_required([:event_id, :reporter_pubkey, :reason])
    |> validate_format(:reporter_pubkey, ~r/^[0-9a-f]{64}$/, message: "must be a 64-char hex pubkey")
    |> validate_inclusion(:status, ["pending", "approved", "dismissed"])
  end
end
