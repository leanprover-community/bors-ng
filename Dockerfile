ARG ELIXIR_VERSION=1.17.3
ARG SOURCE_COMMIT

FROM elixir:${ELIXIR_VERSION} as builder

ENV LANG=C.UTF-8 LC_ALL=C.UTF-8

RUN apt-get update -q && apt-get --no-install-recommends install -y apt-utils ca-certificates build-essential libtool autoconf curl git

RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get --no-install-recommends install -y nodejs

RUN mix local.hex --force && \
    mix local.rebar --force && \
    mix hex.info

WORKDIR /src
ADD ./ /src/

# Set default environment for building
ENV ALLOW_PRIVATE_REPOS=true
ENV MIX_ENV=prod

RUN mix deps.get
RUN cd /src/ && npm install && npm run deploy
RUN mix phx.digest
RUN mix distillery.release --env=$MIX_ENV

# Make the git HEAD available to the released app
RUN if [ -d .git ]; then \
        mkdir /src/_build/prod/rel/bors/.git && \
        git rev-parse --short HEAD > /src/_build/prod/rel/bors/.git/HEAD; \
    elif [ -n ${SOURCE_COMMIT} ]; then \
        mkdir /src/_build/prod/rel/bors/.git && \
        echo ${SOURCE_COMMIT} > /src/_build/prod/rel/bors/.git/HEAD; \
    fi

####

FROM debian:bookworm-slim
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8 LANGUAGE=C.UTF-8
RUN apt-get update -q && apt-get --no-install-recommends install -y git-core libssl3 curl apt-utils ca-certificates

ADD ./script/docker-entrypoint /usr/local/bin/bors-ng-entrypoint
COPY --from=builder /src/_build/prod/rel/ /app/

RUN curl -Ls https://github.com/bors-ng/dockerize/releases/download/v0.7.12/dockerize-linux-amd64-v0.7.12.tar.gz | \
    tar xzv -C /usr/local/bin && \
    /app/bors/bin/bors describe

ENV PORT=4000
ENV DATABASE_AUTO_MIGRATE=true
ENV ALLOW_PRIVATE_REPOS=true

WORKDIR /app
ENTRYPOINT ["/usr/local/bin/bors-ng-entrypoint"]
CMD ["./bors/bin/bors", "foreground"]

EXPOSE 4000
