<div align="center">
  <img src="priv/static/images/mercury_icon.png" alt="Mercury Index-Relay logo" width="180" />
</div>

# GitCitadel Mercury Index-Relay

A Nostr index relay built with Phoenix 1.8 / Elixir. Stores and serves Nostr events via a REST API, with filter-based querying per NIP-01.

**Supported NIPs:** [NIP-11](https://github.com/nostr-protocol/nips/blob/master/11.md) (relay info), [NIP-70](https://github.com/nostr-protocol/nips/blob/master/70.md) (protected events)

## Getting Started

### Prerequisites

- Docker (for the database)
- Elixir ~> 1.15

### Automated setup

Run the setup script — on Debian/Ubuntu it installs Erlang/Elixir from **Team RabbitMQ’s apt repositories** ([Elixir install guide](https://elixir-lang.org/install.html)); on Fedora/RHEL it uses **asdf**. It starts the Apache AGE database container and runs `mix setup`:

```bash
chmod +x setup.sh
./setup.sh
```

After setup, database credentials are written to `.env` (including `REQUIRE_DB=true` for integration tests). Source it before running `mix` tasks that need the DB or asdf’s `mix` in a new terminal:

```bash
source "$HOME/.asdf/asdf.sh"   # if `mix` is not found
source .env
```

### Manual setup

Start the Apache AGE Docker container:

```bash
docker run \
  -d \
  --name gc_age_db \
  -p 5455:5432 \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_DB=gc_index_relay_dev \
  apache/age:release_PG17_1.6.0
```

Set database environment variables, then install dependencies and run migrations:

```bash
export POSTGRES_HOST=localhost
export POSTGRES_PORT=5455
export POSTGRES_USER=postgres
export POSTGRES_PASSWORD=postgres
export POSTGRES_DB=gc_index_relay_dev
export REQUIRE_DB=true

mix setup
```

### Docker Compose (dev)

Postgres is published on **localhost:5455**, same as the manual `docker run` and `setup.sh` flow. The stack works **without** a `.env` file (compose supplies defaults for DB names, the app DB role, and a dev-only `SECRET_KEY_BASE`). Override with `.env` if you want different passwords.

```bash
docker compose -f compose.yaml up -d
```

Use `POSTGRES_PORT=5455` and `POSTGRES_HOST=localhost` in `.env` when running `mix` on the host against this database (compose services talk to Postgres via the hostname `postgres` on the Docker network, not `localhost`).

To reset the compose database volume: `docker compose -f compose.yaml down -v`.

### Starting the server

```bash
source "$HOME/.asdf/asdf.sh"   # if needed
source .env
mix phx.server
```

The relay listens on port **4000** by default (see `PORT` in `config/runtime.exs`). Open [http://localhost:4000](http://localhost:4000). After edits to `config/config.exs`, `config/dev.exs`, or `config/runtime.exs`, restart the server manually; other code is hot-reloaded.

### NIP-11 relay info

```bash
curl -s -H "Accept: application/nostr+json" http://localhost:4000 | jq
```

Edit the relay metadata in `config/config.exs` under the `:relay_info` key.

## Testing

Unit tests (no database required):

```bash
mix test.unit
```

Integration tests (requires the database to be running). The `mix test.integration` task runs a subprocess with `REQUIRE_DB=true` so the Repo starts under test—you do not need to export it yourself. Still `source .env` (or set `POSTGRES_*`) so the test database host and port match your container:

```bash
source .env
mix test.integration
```

Run the full integration probe against the relay API (covers all endpoints, CORS, NIP-11, NIP-70):

```bash
source .env
mix test.integration test/gc_index_relay_web/relay_integration_test.exs
```

The test scenarios are documented in [test/features/relay_api.feature](test/features/relay_api.feature) and cover:

- Discovery (`GET /api`)
- Publishing and rejecting events (`POST /api/events`)
- Deleting events (`DELETE /api/events/:id`)
- Cacheable queries (`GET /api/events?since=&until=&limit=`)
- Filter-based queries (`POST /api/events/filter`)
- Single-event lookup (`GET /api/events/:id`)
- CORS preflight and headers
- NIP-11 relay info document including the `icon` field

Pre-commit check (compile with warnings-as-errors, format, credo, unit tests):

```bash
source .env
mix precommit
```

## Project Overview

### Database

- The database stores Nostr events.
- Nostr events, once signed, are considered immutable.
- Uses Apache AGE (PostgreSQL with graph extensions).

#### Migrations

After modifying an Ecto schema, generate a migration with:

```bash
mix ecto.gen.migration <migration-name>
```

Edit the generated migration file as needed, then apply it:

```bash
mix ecto.migrate
```

Refer to the Fly.io guide [Safe Ecto Migrations](https://github.com/fly-apps/safe-ecto-migrations) for additional information.

## Learn more

- Phoenix: https://www.phoenixframework.org/
- Nostr protocol: https://github.com/nostr-protocol/nostr
- NIP-01 (basic protocol): https://github.com/nostr-protocol/nips/blob/master/01.md
