defmodule GcIndexRelay.Federation.SyncAgreement do
  @moduledoc """
  Ecto schema for federation sync agreements.

  An agreement defines a directional content sync between two communities,
  either on the same instance (intra-instance) or across instances.

  ## Direction

  - `"pull"` — destination pulls from source
  - `"push"` — source pushes to destination
  - `"bidirectional"` — both directions

  ## Status lifecycle

      pending → active | rejected
      active → paused → active
      any → cancelled

  ## Local vs Remote

  When `source_instance_url` or `dest_instance_url` is `nil`, it refers
  to the local instance. Both nil = intra-instance sync (no HTTP needed).
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "sync_agreements" do
    field :source_instance_url, :string
    field :source_community, :string
    field :dest_instance_url, :string
    field :dest_community, :string
    field :direction, :string, default: "pull"
    field :status, :string, default: "pending"
    field :requested_by, :string
    field :approved_by, :string
    field :sync_interval_sec, :integer, default: 300
    field :last_synced_at, :utc_datetime
    field :last_sync_cursor, :utc_datetime
    field :sync_api_key, :string
    timestamps(type: :utc_datetime)
  end

  @valid_directions ~w(pull push bidirectional)
  @valid_statuses ~w(pending active paused rejected cancelled)

  @doc false
  def changeset(agreement, attrs) do
    agreement
    |> cast(attrs, [
      :source_instance_url, :source_community,
      :dest_instance_url, :dest_community,
      :direction, :status,
      :requested_by, :approved_by,
      :sync_interval_sec, :last_synced_at, :last_sync_cursor,
      :sync_api_key
    ])
    |> validate_required([:source_community, :dest_community, :requested_by, :direction, :status])
    |> validate_inclusion(:direction, @valid_directions)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_number(:sync_interval_sec, greater_than_or_equal_to: 60)
    |> validate_format(:requested_by, ~r/^[0-9a-f]{64}$/, message: "must be a 64-char hex pubkey")
  end

  @doc "Returns true if this is an intra-instance (local) sync."
  def local?(%__MODULE__{source_instance_url: nil, dest_instance_url: nil}), do: true
  def local?(_), do: false
end
