defmodule GcIndexRelay.Repo.Migrations.AddRolesAndBans do
  use Ecto.Migration

  def change do
    # ── Site administrators ──
    # First pubkey to POST /api/auth/claim-admin gets inserted here.
    # Additional admins can be added via .env MERCURY_ADMIN_PUBKEYS
    # or by an existing admin via the API.
    create table(:site_admins, primary_key: false) do
      add :pubkey, :string, primary_key: true, size: 64
      add :label, :string, size: 255
      add :claimed_at, :utc_datetime, null: false, default: fragment("NOW()")
    end

    # ── Banned users ──
    # scope = NULL means site-wide ban.
    # scope = "34550:<pubkey>:<id>" means community-specific ban.
    create table(:banned_users) do
      add :pubkey, :string, null: false, size: 64
      add :scope, :string, size: 255  # NULL = site-wide, or community aTag
      add :banned_by, :string, null: false, size: 64
      add :reason, :text
      add :expires_at, :utc_datetime  # NULL = permanent
      timestamps(type: :utc_datetime)
    end

    create unique_index(:banned_users, [:pubkey, :scope],
      name: :banned_users_pubkey_scope_unique,
      nulls_distinct: false
    )
    create index(:banned_users, [:pubkey])
    create index(:banned_users, [:scope])
  end
end
