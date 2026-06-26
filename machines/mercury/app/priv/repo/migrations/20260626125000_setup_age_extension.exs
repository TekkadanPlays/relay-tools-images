defmodule GcIndexRelay.Repo.Migrations.SetupAgeExtension do
  use Ecto.Migration

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS age;"
    execute "LOAD 'age';"
    execute "SET search_path = ag_catalog, \"$user\", public;"
    execute "SELECT create_graph('nostr_graph');"
  end

  def down do
    execute "SELECT drop_graph('nostr_graph', true);"
    execute "DROP EXTENSION IF EXISTS age;"
  end
end
