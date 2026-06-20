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
