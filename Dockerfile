# Dockerfile for Joy — multi-stage build producing a minimal runtime image.
#
# Build:  docker build -t joy .
# Run:    docker run --env-file .env joy
#
# Required env vars at runtime — see docker-compose.yml for full list.

ARG ELIXIR_VERSION=1.18.4
ARG OTP_VERSION=27.3.1
ARG DEBIAN_DISTRO=ubuntu
ARG DEBIAN_VERSION=noble-20260217

ARG BUILDER_IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-${DEBIAN_DISTRO}-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="docker.io/ubuntu:${DEBIAN_VERSION}"                                                                 

# ---------------------------------------------------------------------------
# Stage 1: Build
# ---------------------------------------------------------------------------
FROM ${BUILDER_IMAGE} AS build

RUN apt-get update -y && \
    apt-get install -y build-essential git && \
    apt-get clean && rm -f /var/lib/apt/lists/*_*

WORKDIR /app

ENV MIX_ENV="prod"

RUN mix local.hex --force && mix local.rebar --force

# Fetch deps first — cached unless mix.exs/mix.lock change
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV

RUN mkdir config
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib
COPY assets assets

RUN mix compile
RUN mix assets.deploy

COPY config/runtime.exs config/
COPY rel rel

RUN mix release

# ---------------------------------------------------------------------------
# Stage 2: Runtime — minimal Debian image, no build tools
# ---------------------------------------------------------------------------
FROM ${RUNNER_IMAGE}

RUN apt-get update -y && \
    apt-get install -y libstdc++6 openssl libncurses5 locales ca-certificates && \
    apt-get clean && rm -f /var/lib/apt/lists/*_*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG="en_US.UTF-8" LANGUAGE="en_US:en" LC_ALL="en_US.UTF-8"

WORKDIR /app
RUN chown nobody /app

ENV MIX_ENV="prod"
COPY --from=build --chown=nobody:root /app/_build/${MIX_ENV}/rel/joy ./

USER nobody

# HTTP/HTTPS
EXPOSE 4000

# Erlang distribution: epmd + distribution port range (must match vm.args.eex)
EXPOSE 4369
EXPOSE 9100-9200

CMD ["/app/bin/server"]
