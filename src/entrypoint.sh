#!/bin/bash
# Runtime init for the non-privileged HestiaCP container.
# No systemd: bring services up via SysV `service` and keep PID1 alive.
set -uo pipefail

# Make sure the systemctl shim is in place (apt upgrades during build can have
# restored the real binary).
if [ ! -L /usr/bin/systemctl ]; then
  rm -f /usr/bin/systemctl
  ln -s /usr/bin/systemctl.sh /usr/bin/systemctl
fi

touch /var/log/auth.log 2>/dev/null || true

echo "[entrypoint] starting services..."
# Core data services first, then web/panel.
for svc in mariadb postgresql php8.2-fpm php8.1-fpm php7.4-fpm \
           apache2 nginx exim4 dovecot bind9 named cron \
           hestia; do
  if service "$svc" status >/dev/null 2>&1 || [ -x "/etc/init.d/$svc" ]; then
    service "$svc" start >/dev/null 2>&1 && echo "[entrypoint] started $svc" || true
  fi
done

# Best-effort: start anything else HestiaCP installed that isn't running.
/usr/src/start-all-services.sh 2>/dev/null || true

echo "[entrypoint] ready. Panel should be on https://<host>:8083"

# Keep PID1 alive and surface panel logs.
exec tail -F \
  /var/log/hestia/*.log \
  /var/log/nginx/error.log \
  /dev/null 2>/dev/null
