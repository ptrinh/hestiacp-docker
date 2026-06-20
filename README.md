# hestiacp-docker — non-privileged, multi-arch HestiaCP Docker image

A Docker image of [HestiaCP](https://hestiacp.com) (Hestia Control Panel) that
runs **without `privileged` mode** and ships **multi-arch**
(`linux/amd64` + `linux/arm64`) — the two prerequisites for putting HestiaCP in
the **official [Umbrel](https://umbrel.com) App Store** (which forbids
privileged containers and requires prebuilt, multi-arch, digest-pinned images).

```
ghcr.io/ptrinh/hestiacp:latest
```

Most HestiaCP Docker images run real **systemd** as PID 1 and require
`privileged: true` + `cgroup: host`. This one doesn't.

---

## Quick start

```bash
# No --privileged, no special caps needed.
# 8083 = control panel UI; 80/443 = the websites HestiaCP hosts.
docker run -d --name hestia \
  -p 8083:8083 \
  -p 80:80 -p 443:443 \
  ghcr.io/ptrinh/hestiacp:latest
```

Open `https://localhost:8083` (self-signed cert → accept the warning).

### Ports

| Port | Purpose | Publish it when |
|---|---|---|
| `8083` | HestiaCP control panel (admin UI) | Always — it's how you manage the server |
| `80` / `443` | HTTP/HTTPS for the **websites** HestiaCP hosts | You actually host sites and want visitors to reach them |
| `25`, `587`, `465`, `993`, `53`, `21`, … | Mail / DNS / FTP | Only if you enable those services (off by default) |

Just managing the panel? `-p 8083:8083` is enough. Hosting real sites? Add
`-p 80:80 -p 443:443`.

> **On Umbrel**, ports 80/443 are already used by umbrelOS itself, so the
> Umbrel app publishes hosted sites on **alternate** host ports (e.g.
> `9088:80`, `9448:443`) — see [ptrinh/umbrel-hestiacp](https://github.com/ptrinh/umbrel-hestiacp).
Default admin password is the build placeholder; set your own:

```bash
docker exec hestia /usr/local/hestia/bin/v-change-user-password admin 'YOUR_PASSWORD'
```

## How it stays non-privileged

| HestiaCP normally needs | This image does instead |
|---|---|
| systemd as PID 1 | tini + a `systemctl` **shim** → SysV `service` + [docker-systemctl-replacement](https://github.com/gdraheim/docker-systemctl-replacement) |
| iptables firewall (NET_ADMIN) | installed with `--iptables no` |
| fail2ban (NET_ADMIN/NET_RAW) | installed with `--fail2ban no` |
| kernel disk quota | installed with `--quota no` |
| `privileged: true` + cgroup host | **none** — runs with the default cap set |

Installed feature set: **nginx + Apache + php-fpm**, **MariaDB**, and the
**HestiaCP API**. Mail (exim/dovecot), DNS (bind) and FTP are off by default to
keep the image lean — flip the flags in the `Dockerfile` to enable them (none of
them need privilege).

### Honest trade-offs

- **No in-panel firewall, no fail2ban, no enforced disk quotas** by default. For
  an internet-exposed panel that's a real security downgrade. To get the
  firewall/fail2ban back, re-enable them in the `Dockerfile` and run with
  `cap_add: [NET_ADMIN]` (Umbrel permits declared capabilities).
- HestiaCP does **not** officially support Docker. Version bumps can need image
  fixes; in-place self-update is disabled (see "Updating").

## Version & updates

The installer pulls HestiaCP's `release` branch, so **every build is the latest
stable HestiaCP**. GitHub Actions rebuilds **weekly** (and on every push) and
pushes a fresh multi-arch image to GHCR.

In-place auto-update is intentionally disabled: a pinned container updates by
**pulling a new image**, not by mutating itself (self-update wouldn't survive a
container recreate and can break the non-systemd setup). To update, pull the new
image / redeploy. To force a manual update anyway:
`docker exec hestia /usr/local/hestia/bin/v-update-sys-hestia-all`.

## Slimming (opt-in)

The default image keeps **all** features. To reduce RAM/CPU or drop components
on a running container, use the bundled `slim.sh`:

```bash
docker exec -it hestia slim.sh --all          # tune + remove pma/filemanager + stats off
docker exec -it hestia slim.sh --tune         # just low-RAM/CPU tuning, keep everything
docker exec -it hestia slim.sh --no-pma --dry-run
```

| Flag | Does |
|---|---|
| `--tune` | low-RAM MariaDB (`performance_schema off`, small buffers), php-fpm `pm=ondemand`, opcache, nginx 1 worker |
| `--no-pma` | remove phpMyAdmin |
| `--no-filemanager` | remove the File Manager |
| `--stats-off` | disable RRD graphs + awstats (stops the heaviest idle-CPU crons) |
| `--all` | `--tune --no-pma --no-filemanager --stats-off` |
| `--dry-run` | print actions, change nothing |

To build a nginx-only image (drop Apache entirely):

```bash
docker build --build-arg WITH_APACHE=no -t hestiacp:nginx-only .
```

## Build it yourself

```bash
docker build -t hestiacp:local .            # single-arch, local
# multi-arch is done in CI (.github/workflows/build.yml: buildx + QEMU → GHCR)
```

Build args: `WITH_APACHE` (default `yes`), `HESTIA_HOSTNAME`, `HESTIA_EMAIL`,
`HESTIA_PASSWORD`.

## Image tags

| Tag | Meaning |
|---|---|
| `latest` | newest CI build (latest stable HestiaCP) |
| `<git-sha>` | the exact commit that produced the image |

Pin by digest (`ghcr.io/ptrinh/hestiacp@sha256:…`) for reproducibility.

## Use on Umbrel

The companion community app is
**[ptrinh/umbrel-hestiacp](https://github.com/ptrinh/umbrel-hestiacp)** (today it
ships the proven privileged `smied/hestia-cp` image). This repo is the path to an
official-store-eligible, non-privileged image; once proven, the Umbrel app can
switch to it.

## Status

Experimental spike. Credits: build approach adapted from
[Steveorevo/hestiacp-dockered](https://github.com/Steveorevo/hestiacp-dockered)
and [jhmaverick/hestiacp-docker](https://github.com/jhmaverick/hestiacp-docker).

## License

Packaging is provided as-is. HestiaCP is © the HestiaCP project (GPL-3.0).
