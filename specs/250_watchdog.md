# 250 — Watchdog and heart

Status: implemented
Created: 2026-11-03

Docker restarts a container whose process exits. Two things keep it from exiting when it should:

- **The app hangs**: the VM is running, but the endpoint stops answering. Docker's health check marks the container `unhealthy`, and plain Docker does nothing about that.
- **The VM freezes**: nothing in it runs at all, so nothing in it can notice.

A watchdog covers the first, Erlang's `heart` the second. Each one ends the process, and Docker's `restart: unless-stopped` starts it again. Both are on by default in the release and can be tuned or turned off.

## Watchdog

`PurpleFlow.Watchdog` is a process in the app (not the runner), started after the endpoint. Every `interval` it asks the app's own `GET /health`, over loopback, with a `timeout`. A check fails when the request errors, times out, or gets anything but `200`.

- After `failures` checks fail in a row, it logs an error naming the last failure and halts the VM with exit status 1. It halts outright (`System.halt/1`): a graceful stop could hang on whatever made the app stop answering.
- One check that passes resets the count.
- It does nothing until its first `interval` has passed, so a slow boot isn't a failure.

| Environment variable | Default | Meaning |
|---|---|---|
| `PURPLEFLOW_WATCHDOG_INTERVAL` | `30` | Seconds between checks. `0` turns the watchdog off. |
| `PURPLEFLOW_WATCHDOG_TIMEOUT` | `10` | Seconds one check may take. |
| `PURPLEFLOW_WATCHDOG_FAILURES` | `3` | Failed checks in a row before it halts. |

With the defaults, a hung app is restarted about 90 seconds after it stops answering. The watchdog runs in prod only; dev and test don't start it.

## Heart

`heart` is a small program that ships with Erlang. It runs beside the VM, which sends it a heartbeat every few seconds. If the heartbeats stop for `HEART_BEAT_TIMEOUT` seconds (Erlang's variable, default 60, more than 10), heart kills the VM and runs `HEART_COMMAND`.

- `bin/server` and `bin/runner` start the VM with `-heart`, so the app and the runner both have it. `bin/migrate` and `eval` don't.
- `PURPLEFLOW_HEART=false` starts the VM without it.
- Heart kills the VM only when it has a `HEART_COMMAND` to run afterwards; without one it just exits and leaves the VM frozen. So the scripts default `HEART_COMMAND` to `true`, which does nothing: heart kills the VM, and Docker restarts the container. Set your own `HEART_COMMAND` to run something else first.

## PID 1

Linux ignores a kill signal sent from inside a container to the container's first process (PID 1), and the VM is PID 1 unless something starts it. So the app and the runner run with `init: true` in `docker-compose.yml`: Docker's own small init process becomes PID 1 and starts the VM, and heart's kill works. The init process also passes on signals and cleans up exited processes.

## Tests

- After `failures` failed checks in a row, the watchdog halts with status 1 and logs why.
- A passing check resets the count: fail, pass, fail, fail with `failures = 3` doesn't halt.
- A request error, a timeout, and a non-200 answer each count as a failure.
- Nothing is checked before the first `interval`.
- `interval = 0` doesn't start the watchdog, and neither does dev or test.
- The settings come from the environment variables above, with their defaults; a value out of range is refused, naming the variable.
- The health URL's port comes from the endpoint's config, which exists before the endpoint starts.
- **Against the real stack** (a built release, not `mix test`):
  - With `init: true`, PID 1 is Docker's init, and `heart` runs beside the VM in the app and the runner.
  - A VM frozen with `SIGSTOP` is killed by heart once `HEART_BEAT_TIMEOUT` has passed (exit 137), and `restart: unless-stopped` starts the container again.
  - The watchdog starts in the release, checks the real `/health`, and leaves a healthy app running.
  - A hung endpoint with a running VM can't be staged from outside the container; the watchdog's halt is covered by the unit tests, and the restart after an exit is the one checked with heart.
