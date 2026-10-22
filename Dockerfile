# The production image: a `mix release` on Debian, run as a non-root user.
#
# Versions match .tool-versions and assets/.node-version, so the image runs
# what CI tests. Bump them together (see "Upgrading Elixir / Erlang versions"
# in CLAUDE.md). Every stage uses the same Debian release, since the release
# carries ERTS, which links against the system's glibc and OpenSSL.
ARG ELIXIR_VERSION=1.20.4
ARG OTP_VERSION=29.1.2
ARG NODE_VERSION=20.18.3
ARG DEBIAN_RELEASE=bookworm
# The date of a hexpm/elixir build of ELIXIR_VERSION and OTP_VERSION.
ARG DEBIAN_SNAPSHOT=20261020

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_RELEASE}-${DEBIAN_SNAPSHOT}-slim"
ARG RUNNER_IMAGE="debian:${DEBIAN_RELEASE}-slim"

FROM ${BUILDER_IMAGE} AS deps

RUN apt-get update -q && \
    apt-get install -y --no-install-recommends build-essential git ca-certificates && \
    rm -rf /var/lib/apt/lists/*

ENV LANG=C.UTF-8 LC_ALL=C.UTF-8 MIX_ENV=prod
WORKDIR /src

RUN mix local.hex --force && \
    mix local.rebar --force

# Dependencies first, so a change to lib/ doesn't rebuild them.
COPY mix.exs mix.lock ./
COPY config config
RUN mix deps.get --only prod && \
    mix deps.compile

####

# assets/package.json depends on the phoenix and phoenix_html JS in deps/.
FROM node:${NODE_VERSION}-${DEBIAN_RELEASE}-slim AS assets

WORKDIR /src
COPY --from=deps /src/deps/phoenix deps/phoenix
COPY --from=deps /src/deps/phoenix_html deps/phoenix_html
COPY assets/package.json assets/package-lock.json assets/
RUN cd assets && npm ci
COPY assets assets
RUN cd assets && npm run deploy

####

FROM deps AS builder

COPY lib lib
COPY priv priv
COPY rel rel
COPY --from=assets /src/priv/static priv/static
RUN mix phx.digest && \
    mix release

####

FROM ${RUNNER_IMAGE} AS runtime

# bors's requests trust the system's certificate store (BorsNG.TLS), so this
# install is where its roots come from. The image workflow doesn't cache this
# stage, so each build gets Debian's current ca-certificates and libssl3.
# The build fails if the store still has emSign ECC Root CA - G3, which
# Debian dropped in 20250419~deb12u2 after the keys of intermediates under it
# were compromised. libsctp1 is there because hexpm/elixir's OTP 29 loads it
# at start, and logs its absence, though bors uses no SCTP.
RUN apt-get update -q && \
    apt-get install -y --no-install-recommends libssl3 libncurses6 libstdc++6 libsctp1 ca-certificates curl && \
    rm -rf /var/lib/apt/lists/* && \
    test ! -e /etc/ssl/certs/emSign_ECC_Root_CA_-_G3.pem

ENV LANG=C.UTF-8 LC_ALL=C.UTF-8

# The code stays owned by root, so bors can't change it. What the release
# writes goes to /tmp.
RUN useradd --system --home-dir /app --shell /usr/sbin/nologin bors
WORKDIR /app
COPY --from=builder /src/_build/prod/rel/bors ./
ENV RELEASE_TMP=/tmp ERL_CRASH_DUMP=/tmp/erl_crash.dump
USER bors

# The dashboard footer shows this commit (BorsNG.LayoutView.get_commit/0).
ARG SOURCE_COMMIT=unknown
ENV HEROKU_BUILD_COMMIT=${SOURCE_COMMIT}
ENV PORT=4000
EXPOSE 4000

# Starting needs RELEASE_COOKIE (rel/env.sh.eex). Migrations don't run on
# start; run them first, as a one-off container:
#   docker run --rm --env-file bors.env IMAGE eval "BorsNG.Database.Migrate.run_standalone()"
ENTRYPOINT ["/app/bin/bors"]
CMD ["start"]
