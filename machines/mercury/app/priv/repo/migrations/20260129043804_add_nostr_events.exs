defmodule GcIndexRelay.Repo.Migrations.AddNostrEvents do
  use Ecto.Migration

  def change do
    create table(:events, primary_key: false) do
      add :id, :binary, primary_key: true
      add :pubkey, :binary, null: false
      add :created_at, :utc_datetime, null: false
      add :kind, :integer, null: false
      add :content, :text
      add :sig, :binary, null: false
    end

    create index(:events, [:pubkey])
    create index(:events, [:kind])

    create table(:tags) do
      add :name, :string, null: false
      add :value, :string, null: false
      add :additional_values, {:array, :string}
      add :event_id, references(:events, type: :binary, on_delete: :delete_all), null: false
    end

    create index(:tags, [:event_id])

    create index(:tags, [:name, :value],
             where: "length(name) = 1 AND name ~ '^[a-zA-Z]$'",
             name: :single_letter_tags_index
           )
  end
end
