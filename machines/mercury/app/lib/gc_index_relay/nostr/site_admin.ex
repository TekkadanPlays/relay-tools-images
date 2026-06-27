defmodule GcIndexRelay.Nostr.SiteAdmin do
  @moduledoc """
  Ecto schema for site administrators.

  The first pubkey to claim admin via `POST /api/auth/claim-admin`
  is inserted here. The `.env` variable `MERCURY_ADMIN_PUBKEYS` serves
  as a fallback override for lockout recovery.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:pubkey, :string, autogenerate: false}
  schema "site_admins" do
    field :label, :string
    field :claimed_at, :utc_datetime
  end

  @doc false
  def changeset(admin, attrs) do
    admin
    |> cast(attrs, [:pubkey, :label, :claimed_at])
    |> validate_required([:pubkey])
    |> validate_format(:pubkey, ~r/^[0-9a-f]{64}$/, message: "must be a 64-char hex pubkey")
    |> unique_constraint(:pubkey, name: :site_admins_pkey)
  end
end
