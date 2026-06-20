#!/bin/bash
# systemctl shim. There is no systemd in this container; route every service
# control call to the docker-systemctl-replacement (systemctl3.py), which reads
# the packages' real .service unit files. Routing through systemctl3.py (rather
# than SysV `service`) avoids `service`→`systemctl`→`service` recursion for
# packages that ship only systemd units.
verb="$1"; shift 2>/dev/null || true
case "$verb" in
  reload-or-restart) verb=restart ;;   # systemctl3.py has no reload-or-restart
  reset-failed) exit 0 ;;              # meaningless without systemd
esac
# normalise service name aliases HestiaCP uses
args=()
for a in "$@"; do
  [ "$a" = "mysql" ] && a="mariadb"
  args+=("$a")
done
exec /usr/bin/systemctl3.py "$verb" "${args[@]}"
