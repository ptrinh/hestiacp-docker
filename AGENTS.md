# AGENTS.md — hestiacp-docker

Guidance for AI coding agents working in this repo.

## What this repo is
Builds a **non-privileged, multi-arch** HestiaCP Docker image
(`ghcr.io/ptrinh/hestiacp`) for use on Umbrel / homelab / arm64 boards.

## How it avoids privilege (don't regress this)
- No systemd. PID 1 is **tini**; `entrypoint.sh` starts services via SysV
  `service`.
- `/usr/bin/systemctl` is a **shim** (`src/systemctl.sh`) → SysV `service` for
  known daemons, else `systemctl3.py` (gdraheim docker-systemctl-replacement).
- HestiaCP installed with `--iptables no --fail2ban no --quota no` (the only
  privilege-requiring features). Re-enabling them requires `cap_add: NET_ADMIN`.
- Result must run with the **default** Docker cap set — never add
  `privileged: true`.

## Layout
- `Dockerfile` — debian:12-slim; image hygiene (no-recommends, doc/man/locale
  strip, same-layer clean); installs HestiaCP from the `release` branch (latest
  stable). Build args: `WITH_APACHE` (default yes), `HESTIA_HOSTNAME/EMAIL/PASSWORD`.
- `src/patch-hst-install.php` — re-links the systemctl shim after the
  installer's `apt upgrade` steps (which restore real systemd). Anchored on
  installer strings; update anchors if HestiaCP changes the installer.
- `src/entrypoint.sh` — runtime service start + keep-alive (PID1 work).
- `src/slim.sh` — opt-in RAM/CPU tuning + component removal.
- `.github/workflows/build.yml` — buildx + QEMU → multi-arch
  (linux/amd64,linux/arm64) → GHCR; weekly schedule + on push.

## Gotchas
- HestiaCP CLI isn't on PATH under non-login `docker exec` — call by absolute
  path `/usr/local/hestia/bin/...`.
- arm64 builds are QEMU-emulated in CI and slow (30–90 min).
- Cleanup must happen in the **same RUN layer** as the install, or the bytes
  persist in the layer.
- In-place auto-update cron (`v-update-sys-hestia-all`) is intentionally
  removed; update by rebuilding/pulling a new image.

## Related repo
Umbrel community app: https://github.com/ptrinh/umbrel-hestiacp
