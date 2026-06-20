#!/bin/bash
# systemctl shim: HestiaCP issues `systemctl ...` for service control. There is
# no systemd in this container, so route known services to SysV `service` and
# everything else to the docker-systemctl-replacement (systemctl3.py).
if ( [[ -n "$2" ]] && [[ "$2" =~ (mysql|mariadb|named|bind9|exim4|dovecot|nginx|apache2|cron|clamav-daemon|clamav-freshclam|fail2ban|postgresql|hestia|^php) ]] ); then
  arg1="$1"
  arg2="$2"
  [[ "$arg1" == "reload-or-restart" ]] && arg1=restart
  [[ "$arg2" == "mysql" ]] && arg2=mariadb
  service "$arg2" "$arg1"
else
  systemctl3.py "$@"
fi
