# Cloud agents: getting a working toolchain

For Claude sessions running in a claude.ai cloud container (Ubuntu 24.04,
root, outbound traffic through an HTTPS-only proxy). Everything below was
done and verified in one such session: Elixir installed, `mix test` passing,
and the full `docker compose` stack (app, db, runner) built and running.

A fresh container has none of this. None of it survives the container
either, so each new session repeats it (or a SessionStart hook does).

## Before you start

- **The environment needs broad network access.** The default policy
  blocks `builds.hex.pm` and `repo.hex.pm`, and then nothing below works.
  If a download fails with `403` from the proxy or `CONNECT tunnel failed`,
  ask the user to raise Network access in the environment settings (the
  cloud environment menu in the session's title bar, then Edit).
- **Only HTTPS on port 443 gets out.** The proxy carries HTTPS, nothing
  else: no plain HTTP (apt's default mirrors) and no other ports (SFTP on
  2232, raw database connections, and so on). Don't try to work around it.
- **The container has no IPv6 at all.** Anything that binds `::` fails with
  `eafnosupport`. That matters for the release in Docker; see below.

## 1. Erlang/OTP and Elixir

Match the Dockerfile: Elixir 1.20.2 on OTP 29.0.3. Ubuntu's packages are
far too old (Elixir 1.14), so use Hex's prebuilt builds. No build
dependencies were needed.

```sh
cd /tmp
curl -fsSL -o otp.tgz https://builds.hex.pm/builds/otp/amd64/ubuntu-24.04/OTP-29.0.3.tar.gz
mkdir -p /opt/otp && tar xzf otp.tgz -C /opt/otp --strip-components=1
(cd /opt/otp && ./Install -minimal /opt/otp)

curl -fsSL -o ex.zip https://builds.hex.pm/builds/elixir/v1.20.2-otp-29.zip
mkdir -p /opt/elixir && (cd /opt/elixir && unzip -qo /tmp/ex.zip)

ln -sf /opt/otp/bin/* /usr/local/bin/
ln -sf /opt/elixir/bin/* /usr/local/bin/

export LANG=C.UTF-8   # otherwise Elixir warns about latin1 on every run
elixir --version
```

## 2. Hex and dependencies

On the host, Hex needed no certificate or proxy settings: it picked up the
proxy from `HTTPS_PROXY` and the proxy's CA from the system store. (Inside
Docker builds it's different; see section 5.)

```sh
cd /home/user/purple_flow
mix local.hex --force
mix local.rebar --force
mix deps.get
```

`mix deps.get` reports a low-severity advisory in `lazy_html`, a test-only
dependency. It's not a failure.

## 3. Postgres for dev and test

Use the Postgres 16 server already in the container, not the compose one.
It's installed but not running, and the dev/test config expects the login
`postgres` / `postgres` on localhost.

```sh
service postgresql start
su postgres -c "psql -c \"ALTER USER postgres PASSWORD 'postgres';\""
```

If `service postgresql` doesn't exist, `apt-get install -y postgresql`
first. The test database is created by `mix test` itself (the `test` alias
runs `ecto.create` and `ecto.migrate`). The server can stop on its own
later; if a test run suddenly can't connect, start it again.

## 4. Running the tests

Nothing in the repo sets `PURPLEFLOW_SECRET_KEY`, and the credential tests
need it. Any random key works:

```sh
export LANG=C.UTF-8 PURPLEFLOW_SECRET_KEY=$(openssl rand -base64 32)
mix test          # or: mix precommit, before committing
```

Expect one warning line at boot: without `PURPLEFLOW_RUNNER_ADDRESS`, Code
node scripts run in the test VM itself (specs/070). A `[error] GenServer
... killed` log line during the run is from a test that kills a script on
purpose.

## 5. Docker and the compose stack

Only needed to check something against the real stack (the runner
container's isolation, for example). `mix test` covers everything else.

Start the daemon yourself. It came up with no flags, as root, using the
overlayfs storage driver and cgroups v1:

```sh
(dockerd > /tmp/dockerd.log 2>&1 &)
until docker info > /dev/null 2>&1; do sleep 1; done
```

The repo's `Dockerfile` won't build here unchanged, for three reasons, all
specific to this container and not bugs in the repo:

1. Build steps can't reach the internet except through the proxy, and they
   don't trust its certificate.
2. apt in the Debian images uses plain `http://` mirrors, which the proxy
   refuses (`405 Method Not Allowed`).
3. The release binds IPv6 (`ip: {0, 0, 0, 0, 0, 0, 0, 0}` in
   `config/runtime.exs`), and this kernel has none.

So build from a patched copy of the Dockerfile plus a compose override,
both kept **outside the repo** (use your scratchpad). Never commit these.

```sh
S=/path/to/your/scratchpad
cd /home/user/purple_flow

# After every FROM: trust the proxy's CA (for apt, Hex and curl) and switch apt to https.
awk '{print} /^FROM /{print "COPY --from=ccr ca-bundle.crt /etc/ssl/certs/ccr-ca.crt\nENV HEX_CACERTS_PATH=/etc/ssl/certs/ccr-ca.crt SSL_CERT_FILE=/etc/ssl/certs/ccr-ca.crt CURL_CA_BUNDLE=/etc/ssl/certs/ccr-ca.crt\nRUN sed -i s#http://#https://#g /etc/apt/sources.list.d/*.sources 2>/dev/null; echo Acquire::https::CAInfo \\\"/etc/ssl/certs/ccr-ca.crt\\\"\\; > /etc/apt/apt.conf.d/99ccr; cat /etc/ssl/certs/ccr-ca.crt >> /etc/ssl/certs/ca-certificates.crt"}' \
  Dockerfile > $S/Dockerfile.ccr

# Bind IPv4 instead of IPv6, in the build only.
python3 - "$S/Dockerfile.ccr" <<'PY'
import sys; p = sys.argv[1]; s = open(p).read()
s = s.replace("COPY config/runtime.exs config/\n",
  "COPY config/runtime.exs config/\nRUN sed -i 's/ip: {0, 0, 0, 0, 0, 0, 0, 0}/ip: {0, 0, 0, 0}/' config/runtime.exs\n", 1)
open(p, "w").write(s)
PY

# Build both images through the proxy, with the proxy's CA available as a build context.
python3 - "$S/compose.ccr.yml" "$HTTPS_PROXY" "$S" <<'PY'
import sys; p, proxy, S = sys.argv[1:]
build = f"""    build:
      context: /home/user/purple_flow
      dockerfile: {S}/Dockerfile.ccr
      network: host
      additional_contexts:
        ccr: /root/.ccr
      args:
        HTTP_PROXY: {proxy}
        HTTPS_PROXY: {proxy}
        http_proxy: {proxy}
        https_proxy: {proxy}
"""
open(p, "w").write("services:\n  app:\n" + build + "  runner:\n" + build)
PY
```

A throwaway `.env` (it's gitignored):

```sh
cat > .env <<EOF
SECRET_KEY_BASE=$(openssl rand -base64 48)
PHX_HOST=localhost
PORT=4000
PURPLEFLOW_SECRET_KEY=$(openssl rand -base64 32)
PURPLEFLOW_ADMIN_USERNAME=admin
PURPLEFLOW_ADMIN_PASSWORD=$(openssl rand -hex 12)
EOF
```

Build the two images one at a time. In parallel, Docker Hub rate-limits the
base image lookups (`429 Too Many Requests`); retrying after a short wait
works.

```sh
C="docker compose -f docker-compose.yml -f $S/compose.ccr.yml"
for svc in app runner; do
  for try in 1 2 3 4; do $C build $svc && break; sleep $((try * 15)); done
done
$C up -d --no-build
docker compose ps                      # app should reach "healthy"
curl -s --noproxy '*' localhost:4000/health   # "ok"
```

`--noproxy '*'` matters: without it, curl sends localhost requests to the
proxy. The whole UI (everything but `/health` and `/hooks/*`) asks for
the admin login from `.env`.

## 6. Project-specific notes

- **Two roles, one release.** The same image runs as the app
  (`bin/server`) or as the Code node runner (`bin/runner`, which sets
  `PURPLEFLOW_ROLE=runner`). See specs/070.
- **`RELEASE_DISTRIBUTION=none`** on both containers is deliberate. They
  share a release cookie, so with distribution on, a script in the runner
  could connect into the app's VM. As a result, `bin/purple_flow remote`
  doesn't work; use the UI's Reload button to reload workflows.
- **The runner's isolation can only be checked on the real stack**, not in
  `mix test`. The way to check it is a throwaway Code step that tries to
  read env vars, list `/proc`, and connect to `db:5432`, `app:4000`,
  `app:4369` and the internet, triggered by a webhook. All of that should
  fail, and `app:4000` should answer 403. Delete the workflow afterwards.
- **`bin/start.sh`'s wedge workaround** was never exercised in these
  sessions; nothing here depends on it.
- **No tests needed special handling** beyond `PURPLEFLOW_SECRET_KEY`.

## 7. The live server

The production app is at `https://purple.leenathan.com`. HTTPS works from
the cloud container; SFTP (port 2232) does not. Cloudflare sits in front
and blocks curl's default user agent, so send `-A Mozilla/5.0` on every
request. How workflow files get onto the server is in specs/090; read it
rather than assuming. Any token or password for it comes from the user.
Never commit it or put it in a file inside the repo.
