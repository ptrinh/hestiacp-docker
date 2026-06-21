#!/bin/bash
# systemctl shim. There is no systemd in this container; route service control
# to the docker-systemctl-replacement (systemctl3.py), which reads the packages'
# real .service unit files.
#
# Notable: systemctl3.py's `restart` is unreliable for some units (apache2 ends
# up dead), but `start`/`stop` work — so we implement every restart/reload verb
# as an explicit stop + start. This is what makes HestiaCP's per-change web
# restarts (v-restart-service) succeed.
verb="$1"; shift 2>/dev/null || true

# normalise service-name aliases HestiaCP uses
args=()
for a in "$@"; do
  [ "$a" = "mysql" ] && a="mariadb"
  args+=("$a")
done

case "$verb" in
  reset-failed)
    exit 0 ;;                         # meaningless without systemd
  restart|reload|reload-or-restart|try-restart|force-reload)
    /usr/bin/systemctl3.py stop "${args[@]}" >/dev/null 2>&1
    exec /usr/bin/systemctl3.py start "${args[@]}" ;;
esac

exec /usr/bin/systemctl3.py "$verb" "${args[@]}"
