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

## Installing Elixir

### Preferred: asdf

The repo includes a `.tool-versions` file pinning Erlang and Elixir. With
[asdf](https://asdf-vm.com/) installed:

```bash
asdf plugin add erlang
asdf plugin add elixir
asdf install          # reads .tool-versions automatically
```

Then install Hex and rebar:

```bash
mix local.hex --force
mix local.rebar --force
```

### Alternative: prebuilt ZIPs

If you can't use asdf, install from the GitHub prebuilt ZIPs (pick the ZIP
that matches your installed OTP version):

```bash
# Example: Elixir 1.17.3 for OTP 26
curl -sL https://github.com/elixir-lang/elixir/releases/download/v1.17.3/elixir-otp-26.zip \
     -o /tmp/elixir.zip
mkdir -p /opt/elixir-1.17.3
unzip -q /tmp/elixir.zip -d /opt/elixir-1.17.3
export PATH=/opt/elixir-1.17.3/bin:$PATH
export LANG=en_US.UTF-8
# If your locale is latin1, Elixir needs this flag:
export ELIXIR_ERL_OPTIONS="+fnu"
```

Available ZIP names follow the pattern `elixir-otp-{OTP_MAJOR}.zip`, e.g.
`elixir-otp-26.zip` for OTP 26.

## Hex & rebar: Erlang httpc / TLS-inspection proxy workaround

**This section only applies if you are working in an environment where Erlang's
`httpc` cannot reach `repo.hex.pm` directly** (e.g. Claude Code's remote
sandbox, which runs Erlang traffic through a TLS-inspection proxy whose CA
Erlang does not trust). `curl` typically works because it uses the system CA
bundle. If `mix local.hex` and `mix deps.get` work for you normally, skip this
section.

The workaround is a local HTTP mirror that forwards requests to hex.pm via
`curl`:

```python
# /tmp/hex_mirror.py  – run once before mix deps.get
import subprocess, http.server, socketserver, sys

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        r = subprocess.run(
            ['curl', '-sL', '--compressed', '-w', '\n%{http_code}',
             'https://repo.hex.pm' + self.path],
            capture_output=True, timeout=60)
        body, code = r.stdout.rsplit(b'\n', 1)
        self.send_response(int(code))
        self.send_header('Content-Length', str(len(body)))
        self.end_headers(); self.wfile.write(body)

socketserver.TCPServer.allow_reuse_address = True
with socketserver.ThreadingTCPServer(('127.0.0.1', 8890), H) as s:
    sys.stderr.write('mirror up\n'); s.serve_forever()
```

```bash
python3 /tmp/hex_mirror.py 2>/tmp/mirror.log &

# Point hex at the mirror (127.0.0.1 is typically in no_proxy)
mix hex.config mirror_url http://127.0.0.1:8890
mix hex.config api_url    http://127.0.0.1:8890

# Install hex/rebar the same way if mix local.hex/rebar also fail:
curl -sL https://builds.hex.pm/installs/1.16.0/hex-2.4.1.ez -o /tmp/hex-2.4.1.ez
mix archive.install /tmp/hex-2.4.1.ez --force
curl -sL https://github.com/erlang/rebar3/releases/download/3.22.0/rebar3 \
     -o /usr/local/bin/rebar3 && chmod +x /usr/local/bin/rebar3
mix local.rebar rebar3 /usr/local/bin/rebar3 --force

# Registry signatures can't be verified over plain HTTP:
HEX_UNSAFE_REGISTRY=1 mix deps.get
```

## Key dependency notes

### `jose` must be pinned to `== 1.11.10`

`jose 1.11.11+` uses Erlang's `dynamic()` type (OTP 27 only). The project's
CI matrix includes OTP 26, so we pin:

```elixir
{:jose, "== 1.11.10", override: true}
```

## Known compiler warnings

These warnings are present and intentionally left open pending larger migrations.

### `formats:` — `phoenix_view` migration needed

```
warning: use BorsNG.FooController must receive the :formats option
```

The project uses the legacy `phoenix_view` package and `.eex` templates rather
than the Phoenix 1.7 `Phoenix.Component` / HEEx pattern. Fixing this requires
migrating all controllers, views, and templates — a non-trivial task tracked
separately.

### `use Tesla.Builder` soft-deprecation

```
warning: `use Tesla.Builder` and `use Tesla` are soft-deprecated
```

Comes from the `oauth2` dependency pulling in Tesla's builder macro. Our own
code (`lib/github/github/server.ex`) does not use `use Tesla` — it calls
`Tesla.get!` etc. directly. The proper fix is migrating to Tesla's runtime
configuration API, which affects `github/server.ex` and is tracked separately.

### Charlist sigil in `toml` dep

```
warning: single-quoted strings represent charlists. Use ~c"" if you indeed want a charlist
  deps/toml/lib/decoder.ex:264
```

Comes from the `toml` 0.7.0 dependency, which is the latest release and
largely inactive upstream. Nothing to do here until a new toml release fixes
it or we switch TOML parsers.


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

## Upgrading Elixir / Erlang versions

When bumping versions, update all of these files consistently:

| File | What to change |
|------|---------------|
| `.tool-versions` | Local dev versions (asdf) |
| `.github/workflows/main.yml` | `matrix.elixir`, `matrix.otp_release`, `exfmt` job |
| `elixir_buildpack.config` | Heroku buildpack versions |
| `phoenix_static_buildpack.config` | Node version (if needed) |
| `CLAUDE.md` runtime requirements table | Documentation |

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
