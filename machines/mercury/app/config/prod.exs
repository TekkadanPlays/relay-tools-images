import Config

config :gc_index_relay, GcIndexRelay.Repo,
  url: System.get_env("DATABASE_URL"),
  pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
  ssl: false

# Force using SSL in production. This also sets the "strict-security-transport" header,
# known as HSTS. If you have a health check endpoint, you may want to exclude it below.
# Note `:force_ssl` is required to be set at compile-time.
config :gc_index_relay, GcIndexRelayWeb.Endpoint,
  force_ssl: [rewrite_on: [:x_forwarded_proto]],
  exclude: [
    paths: ["/health"],
    hosts: ["localhost", "127.0.0.1"]
  ]

# Do not print debug messages in production
config :logger, level: :info

# In-app CORS: disable when your L7 proxy sets CORS headers, e.g.:
#   config :gc_index_relay, :cors, enabled: false
# Or use CORS_ENABLED / CORS_ALLOW_ORIGINS in runtime.exs.

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
