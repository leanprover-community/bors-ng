ARG ELIXIR_VERSION=1.17.3-otp-27
ARG NODE_VERSION=20.18.3

FROM elixir:${ELIXIR_VERSION} AS builder

ENV LANG=C.UTF-8 LC_ALL=C.UTF-8

RUN apt-get update -q && apt-get --no-install-recommends install -y \
    build-essential git curl ca-certificates gnupg

ARG NODE_VERSION
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install --no-install-recommends -y nodejs

RUN mix local.hex --force && \
    mix local.rebar --force

WORKDIR /src
COPY . /src

ENV MIX_ENV=prod
RUN mix deps.get --only prod
RUN mix deps.compile

RUN cd assets && npm ci && npm run deploy
RUN mix phx.digest
RUN mix release

####

FROM debian:bookworm-slim
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8 LANGUAGE=C.UTF-8
RUN apt-get update -q && apt-get --no-install-recommends install -y \
    git-core libssl3 curl ca-certificates libncurses6 locales

COPY --from=builder /src/_build/prod/rel/bors /app

ENV PORT=4000
ENV DATABASE_AUTO_MIGRATE=true
ENV ALLOW_PRIVATE_REPOS=true

WORKDIR /app
ENTRYPOINT ["/app/bin/bors"]
CMD ["start"]

EXPOSE 4000
