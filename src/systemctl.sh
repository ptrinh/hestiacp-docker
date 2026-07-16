#!/bin/bash
# systemctl shim. There is no systemd in this container; route service control
# to the docker-systemctl-replacement (systemctl3.py), which reads the packages'
# real .service unit files.
#
# Notable: systemctl3.py's `restart` is unreliable for some units (apache2 ends
# up dead), but `start`/`stop` work  -  so we implement every restart/reload verb
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
    # nginx/apache2 workers can outlive the shim's stop and keep their ports
    # bound (nginx's status listener on 127.0.0.1:8084 is the usual victim);
    # the follow-up start then dies with "bind() ... already in use" and hosted
    # sites go dark while the panel stays up. Make sure the processes are
    # really gone before starting again. (-x exact-matches the comm name, so
    # the panel's separate "hestia-nginx" is never touched.)
    for a in "${args[@]}"; do
      case "${a%.service}" in
        nginx|apache2|exim4|dovecot|named|vsftpd) pname="${a%.service}" ;;
        *) continue ;;
      esac
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -x "$pname" >/dev/null 2>&1 || break
        pkill -x "$pname" 2>/dev/null
        sleep 1
      done
    done
    /usr/bin/systemctl3.py start "${args[@]}"
    rc=$?
    # Wait until the service is actually up before returning, so a caller's
    # follow-up `is-active` check (e.g. HestiaCP's v-restart-service) doesn't
    # race and report a false "restart failed".
    for _ in 1 2 3 4 5 6 7 8; do
      /usr/bin/systemctl3.py is-active "${args[@]}" >/dev/null 2>&1 && break
      sleep 1
    done
    exit $rc ;;
esac

exec /usr/bin/systemctl3.py "$verb" "${args[@]}"
