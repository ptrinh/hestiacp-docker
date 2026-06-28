#!/bin/bash
# Runtime init for the non-privileged HestiaCP container.
# No systemd: start the services from their unit files via the
# docker-systemctl-replacement (systemctl3.py), then keep PID 1 alive.
set -uo pipefail

# Ensure the systemctl shim is in place (apt upgrades during build can restore
# the real binary).
if [ ! -L /usr/bin/systemctl ]; then
  rm -f /usr/bin/systemctl
  ln -s /usr/bin/systemctl.sh /usr/bin/systemctl
fi
touch /var/log/auth.log 2>/dev/null || true

# --- seed persisted data on first run --------------------------------------
# These paths are bind-mounted from the host (${APP_DATA_DIR}) and start empty.
# Copy the image's installed defaults in once so MariaDB/HestiaCP have their
# initial state; on later starts the dirs are already populated and we skip.
seed() {
  local target="$1" src="$2"
  if [ -d "$src" ] && [ -z "$(ls -A "$target" 2>/dev/null)" ]; then
    echo "[entrypoint] seeding $target from image defaults"
    mkdir -p "$target"
    cp -a "$src/." "$target/" 2>/dev/null || true
  fi
}
seed /var/lib/mysql         /opt/seed/mysql
seed /var/lib/postgresql    /opt/seed/postgresql
seed /usr/local/hestia/data /opt/seed/hestia-data
seed /usr/local/hestia/conf /opt/seed/hestia-conf
seed /home                  /opt/seed/home
mkdir -p /backup
chown -R mysql:mysql /var/lib/mysql 2>/dev/null || true
chown -R postgres:postgres /var/lib/postgresql 2>/dev/null || true

# The panel PHP (hestia-php runs as hestiaweb) must be able to write its session
# files; on the bind-mounted data dir the sessions dir comes back root-owned, so
# fix it or logins fail with "session_start ... Permission denied".
SESS=/usr/local/hestia/data/sessions
mkdir -p "$SESS"
chown hestiaweb:hestiaweb "$SESS" 2>/dev/null || chown admin:admin "$SESS" 2>/dev/null || true
chmod 770 "$SESS" 2>/dev/null || true

# --- optional SSH (opt-in, OFF by default) ---------------------------------
# Started before the (slower) service stack so it's reachable quickly. Enabled
# when ENABLE_SSH=true or SSH_AUTHORIZED_KEYS is provided. Key-only (no
# password). Publish a host port for container :22, e.g. `-p 2222:22`. For
# routine admin prefer `docker exec` instead.
if [ "${ENABLE_SSH:-false}" = "true" ] || [ -n "${SSH_AUTHORIZED_KEYS:-}" ]; then
  echo "[entrypoint] enabling sshd (key-only)"
  mkdir -p /root/.ssh /run/sshd
  chmod 700 /root/.ssh
  if [ -n "${SSH_AUTHORIZED_KEYS:-}" ]; then
    printf '%s\n' "$SSH_AUTHORIZED_KEYS" >> /root/.ssh/authorized_keys   # one key, or several newline-separated
  fi
  if [ -s /root/.ssh/authorized_keys ]; then   # a mounted authorized_keys is also honoured
    sort -u /root/.ssh/authorized_keys -o /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
  else
    echo "[entrypoint] WARN: SSH enabled but no authorized key provided  -  no one can log in"
  fi
  mkdir -p /etc/ssh/sshd_config.d
  printf 'PasswordAuthentication no\nPermitRootLogin prohibit-password\n' \
    > /etc/ssh/sshd_config.d/99-hestia.conf
  ssh-keygen -A >/dev/null 2>&1 || true   # host keys (regenerated each start unless /etc/ssh is persisted)
  /usr/sbin/sshd && echo "[entrypoint] sshd listening on :22" || echo "[entrypoint] WARN: sshd failed to start"
fi

# Detect the installed PHP-FPM unit (version-agnostic, e.g. php8.3-fpm).
PHPFPM="$(ls /lib/systemd/system/ 2>/dev/null | grep -oE 'php[0-9.]+-fpm\.service' | head -1 | sed 's/\.service$//')"

echo "[entrypoint] starting services (php-fpm unit: ${PHPFPM:-none})..."
# Full stack. cron + data backends first, then web, then mail/DNS/FTP, then the
# panel. Optional units (apache2, postgresql, mail, named, vsftpd) are skipped
# cleanly if that feature wasn't built in.  bind9 ships its unit as named.service
# on Debian (bind9.service is just an alias), so we start "named".
#
# Ask systemctl3.py which units actually exist rather than probing fixed paths:
# its unit search covers more dirs than /lib + /etc/systemd (e.g. the panel's
# own hestia.service lives elsewhere), so a path probe wrongly skips real units.
KNOWN_UNITS="$(/usr/bin/systemctl3.py list-unit-files 2>/dev/null | awk '{print $1}')"
for svc in cron mariadb ${PHPFPM:-} nginx apache2 exim4 dovecot named vsftpd hestia; do
  [ -n "$svc" ] || continue
  # skip units this build doesn't include (don't WARN on absent optionals)
  printf '%s\n' "$KNOWN_UNITS" | grep -qx "$svc.service" || continue
  if /usr/bin/systemctl3.py start "$svc" >/dev/null 2>&1; then
    echo "[entrypoint] started $svc"
  else
    echo "[entrypoint] WARN: could not start $svc (continuing)"
  fi
done

HEBIN=/usr/local/hestia/bin

# --- PostgreSQL cluster + DB-host registration -----------------------------
# Debian's postgresql.service is just a wrapper that, under systemd, pulls in
# the versioned postgresql@<ver>-main unit; the systemctl shim can't, so the
# real cluster never comes up. Start it directly with pg_ctlcluster (no systemd
# needed). The cluster version is taken from the persisted data dir.
if command -v pg_ctlcluster >/dev/null 2>&1; then
  for PGVER in $(ls /var/lib/postgresql 2>/dev/null | grep -E '^[0-9]+$' | sort -n); do
    if [ -d "/etc/postgresql/$PGVER/main" ]; then
      pg_ctlcluster "$PGVER" main start >/dev/null 2>&1 \
        && echo "[entrypoint] started postgresql $PGVER" \
        || echo "[entrypoint] WARN: postgresql $PGVER start failed (continuing)"
    fi
  done
fi

# The installer registers the localhost MariaDB/PostgreSQL "database hosts"
# (what populates the panel's Add-Database host dropdown) by calling
# v-add-database-host, but that only works when the DB server is reachable -
# which it is NOT during `docker build` (no running services). So we (re)do it
# here at runtime, once, when the servers are actually up. Idempotent: guarded
# by the per-type conf the command writes, so a host you later edit is left be.

# MariaDB: root credentials are in /root/.my.cnf (set by the installer).
if [ ! -s /usr/local/hestia/conf/mysql.conf ]; then
  MPASS="$(sed -n 's/^[[:space:]]*password[[:space:]]*=[[:space:]]*//p' /root/.my.cnf 2>/dev/null | head -1 | tr -d '"')"
  for _ in $(seq 1 20); do mariadb -e 'SELECT 1' >/dev/null 2>&1 && break; sleep 2; done
  if [ -n "$MPASS" ] && "$HEBIN/v-add-database-host" mysql localhost root "$MPASS" >/dev/null 2>&1; then
    echo "[entrypoint] registered MariaDB database host"
  else
    echo "[entrypoint] WARN: MariaDB database host not registered"
  fi
fi

# PostgreSQL: the install never set the postgres SQL password (server was down
# at build), so set a fresh one now via local peer auth, then register the host
# with that password (v-add-database-host writes it into pgsql.conf).
if [ ! -s /usr/local/hestia/conf/pgsql.conf ] && command -v psql >/dev/null 2>&1 \
   && [ -n "${PGVER:-}" ]; then
  for _ in $(seq 1 20); do su -s /bin/sh postgres -c 'psql -tAc "SELECT 1"' >/dev/null 2>&1 && break; sleep 2; done
  PPASS="$(tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 24)"
  if [ -n "$PPASS" ] \
     && su -s /bin/sh postgres -c "psql -c \"ALTER USER postgres PASSWORD '$PPASS'\"" >/dev/null 2>&1 \
     && "$HEBIN/v-add-database-host" pgsql localhost postgres "$PPASS" >/dev/null 2>&1; then
    echo "[entrypoint] registered PostgreSQL database host"
  else
    echo "[entrypoint] WARN: PostgreSQL database host not registered (continuing)"
  fi
fi

# Wait for the web stack to actually be listening before running HestiaCP
# config commands  -  they restart nginx/apache and fail if those aren't ready.
echo "[entrypoint] waiting for web stack..."
for _ in $(seq 1 60); do
  curl -k -s -o /dev/null https://localhost:8083/ 2>/dev/null \
    && (exec 3<>/dev/tcp/127.0.0.1/80) 2>/dev/null && break
  sleep 2
done

# --- set admin password (early, before the rebuild + before "ready") --------
# Umbrel passes APP_PASSWORD into the container env (or set HESTIA_ADMIN_PASSWORD
# directly). Doing this in the entrypoint  -  not a post-start hook  -  and BEFORE
# the slower rebuild means it's applied before the app is reported ready.
# Once-only, guarded by a sentinel in persisted data so a password you later
# change in the panel is never overwritten.
ADMIN_PW="${HESTIA_ADMIN_PASSWORD:-${APP_PASSWORD:-}}"
PW_SENTINEL=/usr/local/hestia/data/.admin-password-set
if [ -n "$ADMIN_PW" ] && [ ! -f "$PW_SENTINEL" ]; then
  for _ in $(seq 1 30); do
    if "$HEBIN/v-list-users" >/dev/null 2>&1 && "$HEBIN/v-change-user-password" admin "$ADMIN_PW"; then
      touch "$PW_SENTINEL"; echo "[entrypoint] admin password initialised"; break
    fi
    sleep 2
  done
fi

# --- ensure web-stack runtime dirs ----------------------------------------
# /var/log is an ephemeral image layer (our build cleans it) and HestiaCP needs
# these to exist before it can register an IP or add a web domain.
mkdir -p /etc/apache2/conf.d/domains /etc/nginx/conf.d/domains \
         /var/log/apache2/domains /var/log/nginx/domains

# --- register the container's current IP with HestiaCP ---------------------
# HestiaCP binds web vhosts to a system IP, and a container's IP can change
# across recreates. Register the current IP (so domains can be created at all),
# and if it changed, repoint existing domains and drop the stale IP.
CUR_IP="$(hostname -i 2>/dev/null | awk '{print $1}')"
if [ -n "$CUR_IP" ] && [ -d /usr/local/hestia/data ]; then
  mkdir -p /usr/local/hestia/data/ips
  OLD_IP="$(ls /usr/local/hestia/data/ips/ 2>/dev/null | grep -vx "$CUR_IP" | head -1)"
  for _ in 1 2 3 4 5; do
    [ -e "/usr/local/hestia/data/ips/$CUR_IP" ] && break
    "$HEBIN/v-add-sys-ip" "$CUR_IP" 255.255.0.0 eth0 admin >/dev/null 2>&1
    [ -e "/usr/local/hestia/data/ips/$CUR_IP" ] && { echo "[entrypoint] registered system IP $CUR_IP"; break; }
    sleep 3
  done
  if [ -n "$OLD_IP" ] && [ "$OLD_IP" != "$CUR_IP" ]; then
    echo "[entrypoint] IP changed ($OLD_IP -> $CUR_IP); repointing web domains"
    for u in $(ls /usr/local/hestia/data/users 2>/dev/null); do
      for d in $("$HEBIN/v-list-web-domains" "$u" plain 2>/dev/null | awk '{print $1}'); do
        "$HEBIN/v-change-web-domain-ip" "$u" "$d" "$CUR_IP" >/dev/null 2>&1
      done
    done
    "$HEBIN/v-delete-sys-ip" "$OLD_IP" >/dev/null 2>&1
  fi
fi

# --- regenerate /etc configs from persisted Hestia data --------------------
# /etc is NOT a persisted volume (only Hestia data/conf, /home and mysql are).
# The actual nginx/apache vhosts and php-fpm pool configs live under /etc and
# are generated *from* that persisted data. So on every container (re)create the
# /etc tree is the bare image layer with no user-domain configs  -  hosted sites
# would 503 (missing vhost AND missing php-fpm pool socket) until rebuilt.
# Rebuild every user's configs from the persisted data, then reload the web
# stack once. This is also what guarantees each domain's php-fpm pool socket
# exists (otherwise php-fpm, started above before these pools are written, never
# creates them).
if [ -d /usr/local/hestia/data/users ]; then
  for u in $(ls /usr/local/hestia/data/users 2>/dev/null); do
    echo "[entrypoint] rebuilding Hestia configs for: $u"
    "$HEBIN/v-rebuild-user" "$u" no >/dev/null 2>&1 \
      || echo "[entrypoint] WARN: rebuild failed for $u"
  done
  for s in ${PHPFPM:-} nginx apache2; do
    [ -n "$s" ] || continue
    [ "$s" = apache2 ] && [ ! -f /lib/systemd/system/apache2.service ] && continue
    "$HEBIN/v-restart-service" "$s" >/dev/null 2>&1 || true
  done
fi

# Quick readiness check on the panel.
for _ in $(seq 1 30); do
  code="$(curl -k -s -o /dev/null -w '%{http_code}' https://localhost:8083/ 2>/dev/null || echo 000)"
  [ "$code" = "200" ] || [ "$code" = "302" ] && { echo "[entrypoint] panel ready on :8083 (HTTP $code)"; break; }
  sleep 2
done

echo "[entrypoint] up. Panel: https://<host>:8083"

# Keep PID 1 alive and surface logs. tini (our ENTRYPOINT) reaps zombies.
exec tail -F \
  /var/log/hestia/*.log \
  /var/log/nginx/error.log \
  /dev/null 2>/dev/null
