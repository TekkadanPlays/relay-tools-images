ExUnit.start()

# Only set up the database sandbox if the Repo was started
# This allows unit tests to run without a database connection
if Application.get_env(:gc_index_relay, :start_repo, true) do
  Ecto.Adapters.SQL.Sandbox.mode(GcIndexRelay.Repo, :manual)
end
