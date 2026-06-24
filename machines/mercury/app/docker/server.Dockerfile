# Dockerfile is modified from the example given on the LogRocket blog
# https://blog.logrocket.com/run-phoenix-application-docker/

ARG ELIXIR_VERSION=1.17.3
ARG OTP_VERSION=27.3.4.7
ARG DEBIAN_VERSION=trixie-20260202-slim
ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

# Set the locale
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

# Install dependencies, including C build tools for libsecp256k1
RUN apt-get update && \
    apt-get install -y --no-install-recommends erlang-dev build-essential make gcc git autoconf automake libtool pkg-config && \
    apt-get clean && \
    rm -f /var/lib/apt/lists/*_*

# Create a build directory and copy in the project files
WORKDIR /app

# Install Hex and Rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Configure for prod build
ENV MIX_ENV="prod"

# Install Elixir application dependencies
COPY mix.exs mix.lock ./
RUN mix deps.get --only ${MIX_ENV}

# Copy in config files before compiling dependencies.
# This ensures config changes will force recompilation of dependencies.
RUN mkdir config
COPY config/config.exs config/${MIX_ENV}.exs config/

# Compile Elixir application dependencies
RUN mix deps.compile

# Copy in static assets and source code
# Note: Swagger docs must be generated before deployment; this image does not generate them.
COPY priv priv
COPY lib lib

# Compile the app for production
RUN mix compile

# Copy in runtime config files.
# Other config files are baked into the compilation, but runtime config is applied at runtime.
COPY config/runtime.exs config/

# Copy in any release files and create a release
COPY rel rel
RUN mix release

# Lean runtime stage (NIFs ship compiled libs; lib_secp256k1 links libsecp256k1 statically in the builder).
FROM ${RUNNER_IMAGE}
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      libstdc++6 \
      libncurses6 \
      locales \
      openssl && \
    apt-get clean && \
    rm -f /var/lib/apt/lists/*_*

# Set the runtime locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && \
    locale-gen
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

# Transfer ownership of the app directory to the runtime user
WORKDIR "/app"
RUN chown 1008:1008 /app

ENV MIX_ENV="prod"

# Copy the final compiled release into the runtime stage
COPY --from=builder --chown=1008:1008 /app/_build/${MIX_ENV}/rel/gc_index_relay ./

USER 1008

# Run the compiled binary
CMD ["/app/bin/server"]
