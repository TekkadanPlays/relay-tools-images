defmodule GcIndexRelay.Nostr.CommunityModerator do
  @moduledoc """
  Ecto schema for community moderators.

  Moderators are appointed by site admins and can manage events
  (hide/unhide), bans, and reports within their assigned community.
  Admins implicitly have mod privileges on all communities.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "community_moderators" do
    field :pubkey, :string
    field :community_atag, :string
    field :appointed_by, :string
    field :appointed_at, :utc_datetime
  end

  @doc false
  def changeset(mod, attrs) do
    mod
    |> cast(attrs, [:pubkey, :community_atag, :appointed_by, :appointed_at])
    |> validate_required([:pubkey, :community_atag, :appointed_by])
    |> validate_format(:pubkey, ~r/^[0-9a-f]{64}$/, message: "must be a 64-char hex pubkey")
    |> validate_format(:appointed_by, ~r/^[0-9a-f]{64}$/, message: "must be a 64-char hex pubkey")
    |> unique_constraint([:pubkey, :community_atag], name: :community_moderators_pubkey_community_unique)
  end
end
