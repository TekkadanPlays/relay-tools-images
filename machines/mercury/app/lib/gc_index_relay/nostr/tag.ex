defmodule GcIndexRelay.Nostr.Tag do
  use Ecto.Schema
  import Ecto.Changeset

  schema "tags" do
    field :name, :string
    field :value, :string
    field :additional_values, {:array, :string}
    belongs_to :event, GcIndexRelay.Nostr.Event, type: :binary
  end

  @doc false
  def changeset(tag, attrs) do
    tag
    |> cast(attrs, [:name, :value, :additional_values])
    |> validate_required([:name])
  end
end
