#!/bin/bash
#
# slim.sh — OPT-IN leaning of a running HestiaCP container.
#
# The default image keeps every feature. Run this when you want a smaller RAM/
# CPU footprint and don't need certain components. Run it INSIDE the container:
#
#   docker exec -it <container> slim.sh --all
#   docker exec -it <container> slim.sh --tune --no-pma
#
# Flags (compose freely):
#   --tune          Low-RAM/low-CPU tuning: MariaDB buffers + performance_schema
#                   off, php-fpm pm=ondemand, opcache on, nginx 1 worker.
#   --no-pma        Remove phpMyAdmin.
#   --no-filemanager Remove the File Manager.
#   --stats-off     Disable RRD graphs + awstats web stats (stops the heaviest
#                   idle-CPU cron wakes).
#   --no-apache     Best-effort switch to nginx-only (see note). Cleaner to
#                   rebuild the image with --build-arg WITH_APACHE=no.
#   --all           --tune --no-pma --no-filemanager --stats-off
#   --dry-run       Print what would happen, change nothing.
#
# Everything is reversible by reinstalling the component / restoring config,
# except data you delete. Review before running on anything important.

set -uo pipefail
HBIN=/usr/local/hestia/bin
DRY=0
do_tune=0 no_pma=0 no_fm=0 stats_off=0 no_apache=0

[ $# -eq 0 ] && { grep '^#' "$0" | sed 's/^# \?//'; exit 0; }

for a in "$@"; do
  case "$a" in
    --tune) do_tune=1 ;;
    --no-pma) no_pma=1 ;;
    --no-filemanager) no_fm=1 ;;
    --stats-off) stats_off=1 ;;
    --no-apache) no_apache=1 ;;
    --all) do_tune=1; no_pma=1; no_fm=1; stats_off=1 ;;
    --dry-run) DRY=1 ;;
    *) echo "unknown flag: $a"; exit 2 ;;
  esac
done

run() { echo "+ $*"; [ "$DRY" = 1 ] || "$@"; }
write() { # write <file> <<<content  (honors dry-run)
  local f="$1"; echo "+ write $f"; [ "$DRY" = 1 ] && { cat; return; }; cat > "$f"; }

# ---- tuning ---------------------------------------------------------------
if [ "$do_tune" = 1 ]; then
  echo "== applying low-RAM / low-CPU tuning =="

  # MariaDB
  mkdir -p /etc/mysql/mariadb.conf.d
  write /etc/mysql/mariadb.conf.d/99-lean.cnf <<'CNF'
[mysqld]
performance_schema             = OFF
innodb_buffer_pool_size        = 48M
innodb_buffer_pool_chunk_size  = 1M
innodb_flush_method            = O_DIRECT
innodb_log_buffer_size         = 4M
innodb_flush_log_at_trx_commit = 2
key_buffer_size                = 8M
aria_pagecache_buffer_size     = 16M
table_open_cache               = 200
table_definition_cache         = 200
thread_cache_size              = 4
max_connections                = 40
tmp_table_size                 = 16M
max_heap_table_size            = 16M
skip-name-resolve
CNF
  run systemctl restart mariadb

  # php-fpm: ondemand + opcache, for every installed PHP version
  for pool in /etc/php/*/fpm/pool.d/www.conf; do
    [ -f "$pool" ] || continue
    echo "+ tuning $pool"
    if [ "$DRY" != 1 ]; then
      sed -i \
        -e 's/^pm = .*/pm = ondemand/' \
        -e 's/^;*pm.process_idle_timeout = .*/pm.process_idle_timeout = 10s/' \
        -e 's/^;*pm.max_requests = .*/pm.max_requests = 500/' \
        "$pool"
      grep -q '^pm.process_idle_timeout' "$pool" || echo 'pm.process_idle_timeout = 10s' >> "$pool"
      grep -q '^pm.max_requests' "$pool" || echo 'pm.max_requests = 500' >> "$pool"
    fi
  done
  for conf in /etc/php/*/fpm/conf.d; do
    [ -d "$conf" ] || continue
    write "$conf/99-opcache-lean.ini" <<'INI'
opcache.enable=1
opcache.memory_consumption=64
opcache.max_accelerated_files=10000
opcache.validate_timestamps=1
opcache.revalidate_freq=60
opcache.jit=0
INI
  done
  for v in /etc/php/*/; do vv=$(basename "$v"); run systemctl restart "php${vv}-fpm"; done

  # nginx: one worker
  for ngx in /etc/nginx/nginx.conf /usr/local/hestia/nginx/conf/nginx.conf; do
    [ -f "$ngx" ] || continue
    [ "$DRY" = 1 ] || sed -i 's/^worker_processes .*/worker_processes 1;/' "$ngx"
    echo "+ set worker_processes 1 in $ngx"
  done
  run systemctl restart nginx
  run systemctl restart hestia
fi

# ---- component removal ----------------------------------------------------
[ "$no_pma" = 1 ] && { echo "== removing phpMyAdmin =="; run "$HBIN/v-delete-sys-pma"; }
[ "$no_fm"  = 1 ] && { echo "== removing File Manager =="; run "$HBIN/v-delete-sys-filemanager"; }

if [ "$stats_off" = 1 ]; then
  echo "== disabling RRD graphs + awstats =="
  run "$HBIN/v-change-sys-config-value" 'RRD' 'no'
  # Drop the heavy periodic crons (RRD every 5m, awstats daily).
  for cf in /var/spool/cron/crontabs/*; do
    [ -f "$cf" ] || continue
    [ "$DRY" = 1 ] || sed -i '/v-update-sys-rrd/d; /webstats/d' "$cf"
    echo "+ pruned rrd/webstats from $cf"
  done
fi

if [ "$no_apache" = 1 ]; then
  echo "== nginx-only (best effort) =="
  echo "NOTE: removing Apache from a running install is fragile."
  echo "      The clean way is to rebuild the image with:"
  echo "         docker build --build-arg WITH_APACHE=no ..."
  run "$HBIN/v-change-sys-web-backend" 'nginx' 2>/dev/null || \
    echo "  v-change-sys-web-backend not available; rebuild instead."
fi

echo "done."
