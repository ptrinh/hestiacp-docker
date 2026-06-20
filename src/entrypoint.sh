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
seed /usr/local/hestia/data /opt/seed/hestia-data
seed /usr/local/hestia/conf /opt/seed/hestia-conf
seed /home                  /opt/seed/home
mkdir -p /backup
chown -R mysql:mysql /var/lib/mysql 2>/dev/null || true

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
    echo "[entrypoint] WARN: SSH enabled but no authorized key provided — no one can log in"
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
for svc in mariadb ${PHPFPM:-} nginx apache2 hestia; do
  [ -n "$svc" ] || continue
  if /usr/bin/systemctl3.py start "$svc" >/dev/null 2>&1; then
    echo "[entrypoint] started $svc"
  else
    echo "[entrypoint] WARN: could not start $svc (continuing)"
  fi
done

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
