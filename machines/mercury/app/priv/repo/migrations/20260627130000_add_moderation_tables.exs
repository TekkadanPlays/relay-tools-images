defmodule GcIndexRelay.Repo.Migrations.AddModerationTables do
  use Ecto.Migration

  def change do
    # ── Community moderators ──
    # Appointed by site admins. A mod can manage events and bans
    # within their assigned community only.
    create table(:community_moderators) do
      add :pubkey, :string, null: false, size: 64
      add :community_atag, :string, null: false, size: 255
      add :appointed_by, :string, null: false, size: 64
      add :appointed_at, :utc_datetime, null: false, default: fragment("NOW()")
    end

    create unique_index(:community_moderators, [:pubkey, :community_atag],
      name: :community_moderators_pubkey_community_unique
    )
    create index(:community_moderators, [:community_atag])

    # ── Reports ──
    # Users can report events. Mods/admins resolve them.
    create table(:reports) do
      add :event_id, :string, null: false, size: 64
      add :reporter_pubkey, :string, null: false, size: 64
      add :community_atag, :string, size: 255  # NULL if not community-specific
      add :reason, :text, null: false
      add :status, :string, null: false, default: "pending", size: 20
      add :resolved_by, :string, size: 64
      add :resolved_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create index(:reports, [:status])
    create index(:reports, [:event_id])
    create index(:reports, [:community_atag])

    # ── Hidden events (soft-delete) ──
    # Mods can hide events from feeds without deleting them permanently.
    create table(:hidden_events, primary_key: false) do
      add :event_id, :string, primary_key: true, size: 64
      add :hidden_by, :string, null: false, size: 64
      add :community_atag, :string, size: 255
      add :reason, :text
      add :hidden_at, :utc_datetime, null: false, default: fragment("NOW()")
    end
  end
end
