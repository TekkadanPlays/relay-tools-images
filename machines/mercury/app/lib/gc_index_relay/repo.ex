defmodule GcIndexRelay.Repo do
  use Ecto.Repo,
    otp_app: :gc_index_relay,
    adapter: Ecto.Adapters.Postgres
end
