FROM public.ecr.aws/docker/library/elixir:1.17-otp-27-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential git openssl ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
ENV MIX_ENV=prod

COPY mix.exs mix.lock* ./
RUN mix local.hex --force && mix local.rebar --force && mix deps.get --only prod

COPY config ./config
COPY lib ./lib
RUN mix compile

EXPOSE 4000
CMD ["mix", "run", "--no-halt"]
