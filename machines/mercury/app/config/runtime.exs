import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/gc_index_relay start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :gc_index_relay, GcIndexRelayWeb.Endpoint, server: true
end

config :gc_index_relay, GcIndexRelayWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# Host-side dev/test: DB published on localhost:5455 (see setup.sh / .env.example).
# Do not set this in :prod: DATABASE_URL omits port on purpose; merging these options
# would keep port 5455 while the hostname came from the URL (e.g. postgres in Docker).
if config_env() != :prod do
  config :gc_index_relay, GcIndexRelay.Repo,
    hostname: System.get_env("POSTGRES_HOST") || "localhost",
    port: String.to_integer(System.get_env("POSTGRES_PORT") || "5455"),
    username: System.get_env("POSTGRES_USER") || "postgres",
    password: System.get_env("POSTGRES_PASSWORD") || "postgres",
    database: System.get_env("POSTGRES_DB") || "gc_index_relay_dev"
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :gc_index_relay, GcIndexRelay.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :gc_index_relay, GcIndexRelayWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  cors_base = Application.get_env(:gc_index_relay, :cors) || []

  cors_enabled =
    case System.get_env("CORS_ENABLED") do
      nil -> Keyword.get(cors_base, :enabled, true)
      v -> String.downcase(String.trim(v)) in ~w(true 1 yes)
    end

  allow_origins =
    case System.get_env("CORS_ALLOW_ORIGINS") do
      nil ->
        Keyword.get(cors_base, :allow_origins, "*")

      raw ->
        raw
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> case do
          [] -> "*"
          ["*"] -> "*"
          list -> list
        end
    end

  config :gc_index_relay,
         :cors,
         cors_base
         |> Keyword.put(:enabled, cors_enabled)
         |> Keyword.put(:allow_origins, allow_origins)

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :gc_index_relay, GcIndexRelayWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end

# NIP-29 Relay Private Key
# Used for synthesizing group discovery events (kind 39000).
config :gc_index_relay,
  relay_privkey: System.get_env("MERCURY_RELAY_PRIVKEY") || nil,
  relay_pubkey: System.get_env("MERCURY_RELAY_PUBKEY") || nil

# LiveKit Integration Config
config :gc_index_relay,
  livekit_api_key: System.get_env("LIVEKIT_API_KEY") || nil,
  livekit_api_secret: System.get_env("LIVEKIT_API_SECRET") || nil,
  livekit_url: System.get_env("LIVEKIT_URL") || nil
