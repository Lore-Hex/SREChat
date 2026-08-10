# Full (non-slim) image: ships a working rebar3 and build tools, which the
# slim image's `mix local.rebar` bootstrap could not reliably reproduce.
FROM hexpm/elixir:1.18.4-erlang-27.3.4.16-debian-bookworm-20260803 AS build

RUN apt-get -o Acquire::Retries=5 update \
    && apt-get -o Acquire::Retries=5 install -y --no-install-recommends build-essential git openssl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
ENV MIX_ENV=prod
RUN mix local.hex --force && mix local.rebar --force

# Deps first (their own layer), compiled serially in dependency order by
# `mix deps.compile` — avoids the parallel "already compiled" race.
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN ERL_FLAGS="+S 1:1" mix deps.compile

COPY config ./config
COPY lib ./lib
RUN ERL_FLAGS="+S 1:1" mix compile

# Self-contained OTP release: no Elixir/mix needed at runtime.
RUN ERL_FLAGS="+S 1:1" mix release --overwrite

# ---- runtime ----
FROM debian:bookworm-slim AS runtime
RUN apt-get -o Acquire::Retries=5 update \
    && apt-get -o Acquire::Retries=5 install -y --no-install-recommends libstdc++6 openssl libncurses6 ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
ENV MIX_ENV=prod
COPY --from=build /app/_build/prod/rel/sre_chat ./
EXPOSE 4000
CMD ["/app/bin/sre_chat", "start"]
