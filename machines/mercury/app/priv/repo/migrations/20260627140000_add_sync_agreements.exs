defmodule GcIndexRelay.Repo.Migrations.AddSyncAgreements do
  use Ecto.Migration

  def change do
    # ── Sync agreements ──
    # Directional, per-community content sync between instances.
    # source_instance_url = NULL means local instance.
    # dest_instance_url = NULL means local instance.
    create table(:sync_agreements) do
      # Source: where content comes FROM
      add :source_instance_url, :string, size: 512   # NULL = local
      add :source_community, :string, null: false, size: 255

      # Destination: where content goes TO
      add :dest_instance_url, :string, size: 512     # NULL = local
      add :dest_community, :string, null: false, size: 255

      # Agreement state
      add :direction, :string, null: false, default: "pull", size: 20
      add :status, :string, null: false, default: "pending", size: 20

      # Who initiated / approved
      add :requested_by, :string, null: false, size: 64
      add :approved_by, :string, size: 64

      # Sync config
      add :sync_interval_sec, :integer, null: false, default: 300
      add :last_synced_at, :utc_datetime
      add :last_sync_cursor, :utc_datetime  # created_at of last synced event

      # Scoped API key for cross-instance auth (issued on approval)
      add :sync_api_key, :string, size: 128

      timestamps(type: :utc_datetime)
    end

    create index(:sync_agreements, [:status])
    create index(:sync_agreements, [:source_instance_url, :source_community])
    create index(:sync_agreements, [:dest_instance_url, :dest_community])
  end
end
