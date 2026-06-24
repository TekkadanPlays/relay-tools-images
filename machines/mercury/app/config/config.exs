# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :gc_index_relay,
  ecto_repos: [GcIndexRelay.Repo],
  generators: [timestamp_type: :utc_datetime]

# In production, set `CORS_ENABLED=false` (runtime) or disable here when a reverse proxy
# adds CORS. Use `allow_origins: ["https://app.example.com"]` to restrict browser access.
config :gc_index_relay, :cors,
  enabled: true,
  allow_origins: "*",
  allow_methods: "GET, POST, DELETE, OPTIONS",
  allow_headers: "content-type, authorization"

# Configure the endpoint
config :gc_index_relay, GcIndexRelayWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: GcIndexRelayWeb.ErrorHTML, json: GcIndexRelayWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: GcIndexRelay.PubSub,
  live_view: [signing_salt: "CiEK2Shl"]

config :gc_index_relay, :phoenix_swagger,
  swagger_files: %{
    "priv/static/swagger.json" => [
      router: GcIndexRelayWeb.Router,
      endpoint: GcIndexRelayWeb.Endpoint
    ]
  }

config :phoenix_swagger, json_library: Jason

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# NIP-11 relay information document
# Served at GET / with Accept: application/nostr+json
# Edit these values to describe your relay instance.
config :gc_index_relay, :relay_info,
  name: "Mercury Index-Relay",
  icon: "favicon.ico",
  banner: "images/mercury_icon.png",
  description:
    "A Nostr index relay for the http protocol, from GitCitadel. Featuring a RESTful API and Swagger, it specializes in swift retrieval or publications, repos, and similar graphs of related events",
  software: "https://git.imwald.eu/silberengel/gc_index_relay.git",
  version: Mix.Project.config()[:version],
  supported_nips: [1, 11, 47, 57, 70],
  limitation: %{
    max_limit: 100,
    auth_required: false,
    payment_required: false,
    restricted_writes: false
  }

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
