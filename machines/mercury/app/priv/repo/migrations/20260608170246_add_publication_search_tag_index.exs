defmodule GcIndexRelay.Repo.Migrations.AddPublicationSearchTagIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create index(:tags, [:name, :event_id],
             where: "name IN ('d', 'title', 'author', 'source') AND value IS NOT NULL",
             name: :tags_publication_metadata_index,
             concurrently: true
           )
  end
end
