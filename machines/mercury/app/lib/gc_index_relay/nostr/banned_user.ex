defmodule GcIndexRelay.Nostr.BannedUser do
  @moduledoc """
  Ecto schema for banned users.

  Bans can be site-wide (scope = nil) or community-scoped
  (scope = community aTag like "34550:<pubkey>:<id>").

  Expiring bans use `expires_at`; permanent bans leave it nil.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "banned_users" do
    field :pubkey, :string
    field :scope, :string
    field :banned_by, :string
    field :reason, :string
    field :expires_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(ban, attrs) do
    ban
    |> cast(attrs, [:pubkey, :scope, :banned_by, :reason, :expires_at])
    |> validate_required([:pubkey, :banned_by])
    |> validate_format(:pubkey, ~r/^[0-9a-f]{64}$/, message: "must be a 64-char hex pubkey")
    |> validate_format(:banned_by, ~r/^[0-9a-f]{64}$/, message: "must be a 64-char hex pubkey")
    |> unique_constraint([:pubkey, :scope], name: :banned_users_pubkey_scope_unique)
  end
end
