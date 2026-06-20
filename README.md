# hestiacp-docker — non-privileged, multi-arch HestiaCP image

An experimental Docker image of [HestiaCP](https://hestiacp.com) that runs
**without `privileged` mode** and as a **multi-arch** image
(`linux/amd64` + `linux/arm64`) — the prerequisites for submitting a HestiaCP
app to the **official Umbrel App Store** (which forbids privileged containers
and requires multi-arch, prebuilt images).

Image: `ghcr.io/ptrinh/hestiacp:latest`

## How it avoids privilege

HestiaCP normally requires systemd (PID 1) and `privileged: true`. This image:

- **Replaces systemd** with a `systemctl` shim that routes service control to
  SysV `service` + [docker-systemctl-replacement](https://github.com/gdraheim/docker-systemctl-replacement),
  so HestiaCP's `systemctl restart …` calls work with no real systemd.
- **Disables the features that need privilege** at install time:
  `--iptables no --fail2ban no --quota no`. These need `NET_ADMIN` / kernel
  quota; they are pure add-ons and the web/db panel works without them.
- Installs a lean set: nginx + apache + php-fpm, MariaDB, and the HestiaCP API.

The result needs **no extra Linux capabilities** and **no privilege**.

### Trade-offs (honest)

- **No in-panel firewall, no fail2ban, no enforced disk quotas.** For a
  panel exposed to the internet this is a real security downgrade. If you want
  the firewall/fail2ban back, re-enable them in the `Dockerfile` and run the
  container with `cap_add: [NET_ADMIN]` (Umbrel permits declared capabilities).
- **Mail/DNS/FTP are off by default** to keep the image lean — flip the
  `--exim/--dovecot/--named/--vsftpd` flags in the `Dockerfile` to enable them
  (they don't require privilege).
- HestiaCP does not officially support Docker; self-update is best avoided
  (pin/hold the `hestia*` packages) and version bumps can need image fixes.

## Version

The `release` branch installer always installs the **latest stable HestiaCP**,
so every CI build (and the weekly scheduled rebuild) is current.

## Build

Pushed automatically by `.github/workflows/build.yml` (Buildx + QEMU →
multi-arch → GHCR). Local single-arch build:

```bash
docker build -t hestiacp:local .
docker run -d --name hestia -p 8083:8083 hestiacp:local   # no --privileged
```

Then open `https://localhost:8083` (self-signed cert).

## Status

Experimental spike. The companion Umbrel community app lives at
[ptrinh/umbrel-hestiacp](https://github.com/ptrinh/umbrel-hestiacp) (currently
ships the proven privileged `smied/hestia-cp` image); this repo is the path
toward an official-store-eligible, non-privileged image.
