# hestiacp-docker  -  non-privileged, multi-arch HestiaCP Docker image

A Docker image of [HestiaCP](https://hestiacp.com) (Hestia Control Panel) that
runs **without `privileged` mode** and ships **multi-arch**
(`linux/amd64` + `linux/arm64`)  -  the two prerequisites for putting HestiaCP in
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

Open `https://localhost:8083` (self-signed cert -> accept the warning).

### Ports

| Port | Purpose | Publish it when |
|---|---|---|
| `8083` | HestiaCP control panel (admin UI) | Always  -  it's how you manage the server |
| `80` / `443` | HTTP/HTTPS for the **websites** HestiaCP hosts | You actually host sites and want visitors to reach them |
| `25` / `465` / `587` | Mail: SMTP (receive) / SMTPS / submission | You host mailboxes. Note: residential ISPs usually block OUTBOUND 25, so sending may need a smarthost |
| `143` / `993`, `110` / `995` | Mail: IMAP(S), POP3(S) | Mail clients need to fetch mail |
| `53` tcp+udp | DNS (bind) | You serve authoritative DNS for your zones |
| `21` + `12000-12100` | FTP + passive data range | You want FTP instead of SFTP/File Manager. Set `FTP_PASV_ADDRESS=<host LAN IP>` so passive mode advertises a reachable address |

Just managing the panel? `-p 8083:8083` is enough. Hosting real sites? Add
`-p 80:80 -p 443:443`.

> **On Umbrel**, ports 80/443 are already used by umbrelOS itself, so the
> Umbrel app publishes hosted sites on **alternate** host ports (e.g.
> `9088:80`, `9448:443`)  -  see [ptrinh/umbrel-hestiacp](https://github.com/ptrinh/umbrel-hestiacp).

### SSH access (optional, off by default)

For routine admin, prefer `docker exec -it hestiacp bash` (no open port). For
hosting users' SSH/SFTP, add their keys **in the HestiaCP panel**
(`v-add-user-ssh-key`)  -  there's also a built-in web terminal.

If you specifically want to SSH into the container (e.g. scp / git-over-ssh),
enable a **key-only** sshd by setting `ENABLE_SSH=true` and providing a public
key, then publish a port:

```bash
docker run -d --name hestia \
  -p 8083:8083 -p 80:80 -p 443:443 \
  -p 2222:22 \
  -e ENABLE_SSH=true \
  -e SSH_AUTHORIZED_KEYS="ssh-ed25519 AAAA... you@host" \
  ghcr.io/ptrinh/hestiacp:latest
# ssh -p 2222 root@<host>
```

`SSH_AUTHORIZED_KEYS` accepts one key or several newline-separated; a mounted
`/root/.ssh/authorized_keys` is also honoured. Password auth is disabled
(key-only). Host keys regenerate each start unless you persist `/etc/ssh`. This
is **disabled in the Umbrel app** (the store expects web-UI-only access).

### Docker Compose

A ready-to-use [`docker-compose.example.yml`](docker-compose.example.yml) is
included (persists data in `./data/*`, no privileged mode):

```bash
docker compose -f docker-compose.example.yml up -d
```
Default admin password is the build placeholder; set your own:

```bash
docker exec hestia /usr/local/hestia/bin/v-change-user-password admin 'YOUR_PASSWORD'
```

## How it stays non-privileged

| HestiaCP normally needs | This image does instead |
|---|---|
| systemd as PID 1 | tini + a `systemctl` **shim** -> SysV `service` + [docker-systemctl-replacement](https://github.com/gdraheim/docker-systemctl-replacement) |
| iptables firewall (NET_ADMIN) | installed with `--iptables no` |
| fail2ban (NET_ADMIN/NET_RAW) | installed with `--fail2ban no` |
| kernel disk quota | installed with `--quota no` |
| `privileged: true` + cgroup host | **none**  -  runs with the default cap set |

Installed feature set: **nginx + Apache + php-fpm**, **MariaDB + PostgreSQL**
(with phpMyAdmin/phpPgAdmin through the panel), **mail (exim + dovecot)**,
**DNS (bind)**, **FTP (vsftpd)**, **File Manager**, **cron and backups**, and
the **HestiaCP API**. Apache is on by default (build with
`--build-arg WITH_APACHE=no` for a leaner nginx-only image).

Mail/DNS/FTP persistence: mailboxes, DKIM keys, DNS zones and FTP accounts
live under the persisted `/home` + `/usr/local/hestia/data` volumes, and the
`/etc` configs for them are regenerated from that data on every container
start. The one extra volume you must add for mail is the queue:
`-v ./data/exim-spool:/var/spool/exim4`. Publish the service ports from the
table above; without them the daemons run but are unreachable from outside.

### Honest trade-offs

- **No in-panel firewall, no fail2ban, no enforced disk quotas** by default. For
  an internet-exposed panel that's a real security downgrade. To get the
  firewall/fail2ban back, re-enable them in the `Dockerfile` and run with
  `cap_add: [NET_ADMIN]` (Umbrel permits declared capabilities).
- HestiaCP does **not** officially support Docker. Version bumps can need image
  fixes; in-place self-update is disabled (see "Updating").
- **`/etc` is not persisted** (only Hestia data/conf, `/home` and MariaDB are).
  The generated nginx/apache vhosts and php-fpm pools live under `/etc`, so the
  entrypoint **rebuilds them from the persisted Hestia data on every start**
  (`v-rebuild-user`). One consequence: the image ships a **single PHP version**
  (`--multiphp no`), so persisted data whose web domains reference a *different*
  PHP backend (e.g. migrated from another host running PHP 8.1 while this image
  ships 8.3) will fail to get a matching php-fpm pool and 503. Match the image's
  PHP version to your data, or rebuild the image with `--multiphp yes`.

## Web hosting

The image is **nginx-only by default**, which is what makes in-container hosting
work: adding a web domain serves correctly (HTTP 200), and sites persist and are
rebuilt from the persisted data on every start (`v-rebuild-user`), including a
changed container IP (auto-repointed on start). The container also auto-registers
its current IP and creates the web-stack runtime dirs on start.

Notes:

- On the very first domain you add, HestiaCP may print "Restart of nginx failed"
  even though the site serves fine; subsequent adds are clean. (HestiaCP's
  restart status check can race the non-systemd restart.)
- **Apache** is opt-in (`--build-arg WITH_APACHE=yes`). With Apache, live domain
  changes are NOT reliable in a container (Apache's restart fails and leaves the
  site down until an app restart), so nginx-only is the recommended default.
- For heavy production hosting, a dedicated VM is still the most robust option.

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

To include Apache (adds .htaccess support; see the Web hosting note):

```bash
docker build --build-arg WITH_APACHE=yes -t hestiacp:apache .
```

## Build it yourself

```bash
docker build -t hestiacp:local .            # single-arch, local
# multi-arch is done in CI (.github/workflows/build.yml: buildx + QEMU -> GHCR)
```

Build args: `WITH_APACHE` (default `yes`), `HESTIA_HOSTNAME`, `HESTIA_EMAIL`,
`HESTIA_PASSWORD`.

## Image tags

| Tag | Meaning |
|---|---|
| `latest` | newest CI build (latest stable HestiaCP) |
| `<git-sha>` | the exact commit that produced the image |

Pin by digest (`ghcr.io/ptrinh/hestiacp@sha256:...`) for reproducibility.

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

Packaging is provided as-is. HestiaCP is (c) the HestiaCP project (GPL-3.0).
