import Config

config :gc_index_relay, :start_repo, System.get_env("REQUIRE_DB") == "true"

# Allow ConnCase HTTP tests to use the same SQL.Sandbox checkout as the test process (see Endpoint).
config :gc_index_relay, sql_sandbox: true

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :gc_index_relay, GcIndexRelay.Repo,
  username: System.get_env("POSTGRES_USER", "postgres"),
  password: System.get_env("POSTGRES_PASSWORD", "postgres"),
  database:
    "#{System.get_env("POSTGRES_DB", "gc_index_relay_dev")}#{System.get_env("MIX_TEST_PARTITION")}",
  hostname: System.get_env("POSTGRES_HOST", "localhost"),
  port: String.to_integer(System.get_env("POSTGRES_PORT", "5455")),
  show_sensitive_data_on_connection_error: true,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :gc_index_relay, GcIndexRelayWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "gSUz4Ek3rc6PKcY/imWwjsMbwk8g4+aS5HmD1/MyAmqlbSw+r0V83NjR7H0jnwI6",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
