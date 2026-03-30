# CLAUDE.md – Bors-NG developer notes for AI agents

## Project overview

Bors-NG is a GitHub merge bot written in Elixir/Phoenix. It manages pull-request
queuing, batching, and automatic merging via the GitHub API.

## Runtime requirements

| Component | Required version |
|-----------|-----------------|
| Elixir    | 1.16.3 or 1.17.3 |
| OTP       | 26.x (with Elixir 1.16) or 27.x (with Elixir 1.17) |
| PostgreSQL | 13+ (primary DB; MySQL is also supported via BORS_DATABASE=mysql) |

**OTP 25 is NOT supported** – see the `jose` pin below.

## Getting Elixir in this sandbox

The system apt package only provides Elixir 1.14. Install a current version from
the GitHub prebuilt ZIP instead:

```bash
curl -sL https://github.com/elixir-lang/elixir/releases/download/v1.17.3/elixir-otp-25.zip \
     -o /tmp/elixir.zip     # use elixir-otp-26.zip if OTP 26 is installed
mkdir -p /opt/elixir-1.17.3
unzip -q /tmp/elixir.zip -d /opt/elixir-1.17.3
export PATH=/opt/elixir-1.17.3/bin:$PATH
export LANG=en_US.UTF-8
export ELIXIR_ERL_OPTIONS="+fnu"   # needed because locale may be latin1
```

## Hex & rebar in this sandbox

The sandbox proxy does TLS inspection. Erlang's `httpc` cannot connect to
`repo.hex.pm` through the proxy. Work around this by running a local HTTP
mirror that fetches via `curl` (which does trust the proxy CA):

```bash
# 1. Start the mirror (see /tmp/hex_mirror2.py in the session – or recreate it)
python3 /tmp/hex_mirror2.py 2>/tmp/mirror.log &

# 2. Point hex at the mirror
mix hex.config mirror_url http://127.0.0.1:8890
mix hex.config api_url    http://127.0.0.1:8890

# 3. Install hex for this Elixir version (since mix local.hex also fails)
curl -sL https://builds.hex.pm/installs/1.16.0/hex-2.4.1.ez -o /tmp/hex-2.4.1.ez
mix archive.install /tmp/hex-2.4.1.ez --force

# 4. Install rebar3 (mix local.rebar also fails through the proxy)
curl -sL https://github.com/erlang/rebar3/releases/download/3.22.0/rebar3 \
     -o /usr/local/bin/rebar3 && chmod +x /usr/local/bin/rebar3
mix local.rebar rebar3 /usr/local/bin/rebar3 --force
```

After that, `mix deps.get` works with `HEX_UNSAFE_REGISTRY=1` (the registry
signature cannot be verified over plain HTTP):

```bash
ELIXIR_ERL_OPTIONS="+fnu" HEX_UNSAFE_REGISTRY=1 mix deps.get
```

## Key dependency notes

### `jose` must be pinned to `== 1.11.10`

`jose 1.11.11+` uses Erlang's `dynamic()` type (OTP 27 only). The project's
CI matrix includes OTP 26, so we pin:

```elixir
{:jose, "== 1.11.10", override: true}
```

### `ex_link_header 0.0.5` mix.exs patch

`ex_link_header 0.0.5` (the only released version) has a `mix.exs` that calls
private functions without parentheses – valid in Elixir 1.2 but a compile error
in 1.16+. After `mix deps.get`, patch the file:

```bash
sed -i 's/description: description,/description: description(),/' deps/ex_link_header/mix.exs
sed -i 's/package: package,/package: package(),/'                 deps/ex_link_header/mix.exs
sed -i 's/deps: deps]/deps: deps()]/'                             deps/ex_link_header/mix.exs
```

This patch is NOT committed to the repo (it lives in `deps/` which is
`.gitignore`d). It will need to be re-applied after a `mix deps.get --force`.

## Building

```bash
# Development
ELIXIR_ERL_OPTIONS="+fnu" mix deps.get
ELIXIR_ERL_OPTIONS="+fnu" mix compile

# Format check (must pass CI)
ELIXIR_ERL_OPTIONS="+fnu" mix format --check-formatted
```

## Running tests

Tests require a running PostgreSQL instance. The default test config expects:

```
postgresql://postgres:Postgres1234@localhost/bors_test
```

Set `BORS_DATABASE=mysql` and configure `config/test.exs` to run against MySQL
instead.

```bash
BORS_DATABASE=postgresql ELIXIR_ERL_OPTIONS="+fnu" mix test
```

The `test` alias in `mix.exs` auto-runs `ecto.create` and `ecto.migrate`.

## CI

The CI workflow is `.github/workflows/main.yml`. Key jobs:

| Job | Elixir | OTP | Notes |
|-----|--------|-----|-------|
| test (matrix) | 1.16.3, 1.17.3 | 26.2.5, 27.2 | PostgreSQL + MySQL |
| exfmt | 1.16.3 | 26.2.5 | `mix format --check-formatted` |
| lint-test | — | — | Helm chart linting only |

The `ci-success` aggregator job is what bors itself waits for.

## Architecture overview

```
lib/
  application.ex          OTP application / supervisor tree
  github/                 GitHub API client (Tesla-based)
  worker/
    batcher.ex            Core batching logic
    batcher/registry.ex   GenServer tracking active batchers
    attemptor.ex          Single-PR attempt runner
    syncer.ex             Repo/installation syncer
    branch_deleter.ex     Cleanup worker
  web/                    Phoenix web layer (controllers, views, templates)
  database/               Ecto schemas and repos
    repo.ex               Dynamic repo wrapper (switches pg/mysql at runtime)
    repo_postgres.ex
    repo_mysql.ex
```

The database backend is selected at runtime via `BORS_DATABASE` env var
(default: `postgresql`). `:persistent_term` holds the chosen repo module.
