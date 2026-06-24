defmodule GcIndexRelay.Repo.Migrations.AllowNullTagValue do
  use Ecto.Migration

  def change do
    alter table(:tags) do
      modify :value, :string, null: true, from: {:string, null: false}
    end
  end
end
