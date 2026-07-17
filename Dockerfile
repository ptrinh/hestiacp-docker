# Non-privileged, multi-arch (amd64/arm64) HestiaCP image.
#
# HestiaCP normally needs systemd + privileged mode. This image removes that by
# replacing systemd with a `systemctl` shim (SysV `service` + the
# docker-systemctl-replacement) and installing HestiaCP with the firewall,
# fail2ban and disk-quota features disabled (the parts that need NET_ADMIN /
# kernel quota). The result runs with NO extra capabilities and NO privilege.
#
# Base: debian:12-slim (bookworm)  -  small, and a HestiaCP-supported OS.
# Version: the installer pulls HestiaCP's `release` branch, i.e. the latest
# stable release at build time, so each build is automatically up to date.
#
# Scope: the full panel. Web hosting (nginx + Apache + PHP-FPM), databases
# (MariaDB + PostgreSQL, phpMyAdmin/phpPgAdmin), mail (exim + dovecot), DNS
# (bind), FTP (vsftpd, passive ports 12000-12100), File Manager, cron and
# backups. Off: clamav/spamassassin (heavy) and the privilege-requiring
# firewall / fail2ban / disk quota.
#
# To actually USE mail/DNS/FTP you must publish their ports (see EXPOSE at the
# bottom / the compose example) and persist /var/spool/exim4 (the mail queue).
# Mailboxes, DKIM keys, DNS zones and FTP accounts all live under /home and
# /usr/local/hestia/data, which are the standard persisted volumes; the /etc
# configs for them are regenerated from that data on every container start.
# To slim a running container (remove phpMyAdmin/File Manager, tune RAM/CPU,
# disable stats) run the bundled `slim.sh`.
#
# Approach adapted from Steveorevo/hestiacp-dockered, reworked for a small
# Debian base, multi-arch CI builds, and a clean runtime entrypoint.
FROM debian:12-slim

ARG DEBIAN_FRONTEND=noninteractive
# Must be a valid FQDN with >=2 dots  -  HestiaCP's installer rejects single-label
# / single-dot names (validate_hostname per RFC1178) and aborts.
ARG HESTIA_HOSTNAME=hestia.umbrel.local
ARG HESTIA_EMAIL=admin@hestiacp.local
# Build-time placeholder password; reset at first run from APP_PASSWORD by the entrypoint.
ARG HESTIA_PASSWORD=changeme
# Full-panel build. Apache included by default; set to "no" for a leaner
# nginx-only image (note: live domain changes are more reliable nginx-only).
ARG WITH_APACHE=yes

# --- image hygiene (no feature loss) ---------------------------------------
# Strip docs/man/locales and stop apt pulling recommends/suggests. These apply
# to every package installed after this layer.
RUN printf '%s\n' \
      'path-exclude /usr/share/doc/*' 'path-include /usr/share/doc/*/copyright' \
      'path-exclude /usr/share/man/*' \
      'path-exclude /usr/share/info/*' \
      'path-exclude /usr/share/locale/*' 'path-include /usr/share/locale/locale.alias' \
      > /etc/dpkg/dpkg.cfg.d/01_nodoc \
 && printf '%s\n' 'APT::Install-Recommends "false";' 'APT::Install-Suggests "false";' \
      > /etc/apt/apt.conf.d/99lean

RUN apt-get update && apt-get -y upgrade \
 && apt-get install -y --no-install-recommends \
      sudo wget curl ca-certificates git unzip lsb-release php-cli python3 procps tini \
 && apt-get remove -y apparmor || true \
 && apt-get clean && rm -rf /var/lib/apt/lists/* /var/log/* /tmp/*

# --- systemd replacement ---------------------------------------------------
COPY src/docker-systemctl-replacement/systemctl3.py /usr/bin/systemctl3.py
COPY src/docker-systemctl-replacement/journalctl3.py /usr/bin/journalctl3.py
COPY src/systemctl.sh /usr/bin/systemctl.sh
RUN chmod +x /usr/bin/systemctl3.py /usr/bin/journalctl3.py /usr/bin/systemctl.sh \
 && mv /usr/bin/systemctl  /usr/bin/systemctl.original  || true \
 && mv /usr/bin/journalctl /usr/bin/journalctl.original || true \
 && ln -s /usr/bin/systemctl.sh  /usr/bin/systemctl \
 && ln -s /usr/bin/journalctl3.py /usr/bin/journalctl

# --- HestiaCP install ------------------------------------------------------
WORKDIR /usr/src
COPY src/patch-hst-install.php /usr/src/patch-hst-install.php

RUN curl -fsSL https://raw.githubusercontent.com/hestiacp/hestiacp/release/install/hst-install-debian.sh \
      -o hst-install-debian.sh \
 && chmod +x hst-install-debian.sh \
 && php /usr/src/patch-hst-install.php /usr/src/hst-install-debian.sh \
 # Neutralize the installer's service-start "check_result ... start failed" and
 # default-domain checks. Without systemd these "fail" and abort the install
 # partway, silently skipping the LATE steps (File Manager, cron jobs, DB-host
 # registration, mail/DNS config). Making them non-fatal lets the install run to
 # completion; we start the services ourselves at runtime.
 && sed -i -E 's/^[[:space:]]*check_result \$\? "[^"]*start failed[^"]*"[[:space:]]*$/true/' hst-install-debian.sh \
 && sed -i -E 's/^[[:space:]]*check_result \$\? "[^"]*(create|domain)[^"]*"[[:space:]]*$/true/' hst-install-debian.sh \
 && touch /var/log/auth.log

# Full panel: nginx (+ Apache) + PHP-FPM, MariaDB + PostgreSQL, mail
# (exim + dovecot), DNS (bind), FTP (vsftpd), File Manager + cron (added by
# the installer's late steps, now that it runs to completion). Off: clamav /
# spamassassin (heavy) and the privilege-requiring firewall / fail2ban / quota.
RUN ./hst-install-debian.sh \
      --apache "$WITH_APACHE" --phpfpm yes --multiphp no \
      --vsftpd yes --proftpd no --named yes \
      --mysql yes --postgresql yes \
      --exim yes --dovecot yes --sieve no \
      --clamav no --spamassassin no \
      --iptables no --fail2ban no --quota no \
      --api yes --with-debs no \
      --port 8083 \
      --hostname "$HESTIA_HOSTNAME" \
      --email "$HESTIA_EMAIL" \
      --username admin \
      --password "$HESTIA_PASSWORD" \
      --lang en --force --interactive no </dev/null \
 # fail loudly if the installer aborted silently (e.g. bad hostname) instead of
 # shipping an empty image. NOTE: the localhost DB-host registration (the panel's
 # Add-Database host dropdown) can't happen here - MariaDB/PostgreSQL aren't
 # running during `docker build` - so the entrypoint registers them at runtime.
 && test -x /usr/local/hestia/bin/v-list-users \
 # Strip the build container's throwaway system IP and the default web domain
 # the installer binds to it. At runtime the container gets a DIFFERENT IP, and
 # a baked listen config for the old one makes apache/nginx fail to bind ("could
 # not bind to address <buildip>"). The entrypoint registers the real IP fresh.
 && : > /usr/local/hestia/data/users/admin/web.conf \
 && rm -rf /home/admin/web/* \
 && rm -f /etc/apache2/conf.d/domains/* /etc/nginx/conf.d/domains/* \
 && for ip in $(ls /usr/local/hestia/data/ips/ 2>/dev/null); do \
       rm -f "/etc/apache2/conf.d/$ip.conf" "/etc/nginx/conf.d/$ip.conf"; done \
 && rm -f /usr/local/hestia/data/ips/* \
 # Behind a reverse proxy the panel's external port never matches its internal
 # SERVER_PORT, so HestiaCP's origin/port CSRF heuristic always blocks login
 # with "Potential CSRF use detected". Relax it (the per-session form token
 # still protects requests); HestiaCP documents this for proxied panels.
 && if grep -q POLICY_CSRF_STRICTNESS /usr/local/hestia/conf/hestia.conf; then \
       sed -i "s/POLICY_CSRF_STRICTNESS=.*/POLICY_CSRF_STRICTNESS='0'/" /usr/local/hestia/conf/hestia.conf; \
    else echo "POLICY_CSRF_STRICTNESS='0'" >> /usr/local/hestia/conf/hestia.conf; fi \
 # cleanup: downloaded debs, apt caches, logs (same layer so bytes don't persist)
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* /root/*.deb /usr/src/*.deb /var/cache/apt/archives/*.deb \
           /var/log/* /tmp/* \
 # in a pinned container we patch by rebuilding, so stop in-place auto-update.
 # (per-iteration `|| true` keeps this from masking a real failure in the chain
 # above - the whole RUN still fails if any earlier `&&` step fails.)
 && for cf in /var/spool/cron/crontabs/*; do [ -f "$cf" ] && sed -i '/v-update-sys-hestia-all/d' "$cf" || true; done

# Re-assert the shim in case the installer's apt upgrades restored real systemd.
RUN rm -f /usr/bin/systemctl && ln -s /usr/bin/systemctl.sh /usr/bin/systemctl

# Install HestiaCP's web-UI composer dependencies. The installer doesn't run
# this, so without it the panel PHP-fatals ("vendor/autoload.php not found") AND
# the PHP helper that runs during service restarts fails  -  breaking both the
# login UI and live domain changes. Deps land in web/inc/vendor and web/src/vendor.
RUN /usr/local/hestia/bin/v-add-sys-dependencies \
 && test -f /usr/local/hestia/web/inc/vendor/autoload.php \
 && rm -rf /root/.composer/cache /tmp/* 2>/dev/null || true

# The panel's bundled php-fpm forces Secure + SameSite=Strict on its session
# cookie. Behind Umbrel's app_proxy the browser reaches the panel over plain
# HTTP, which drops a Secure cookie -> no session -> login bounces. Relax to a
# non-Secure, SameSite=Lax cookie so the login flow works through the proxy.
RUN sed -i 's/^php_admin_flag\[session.cookie_secure\] = on/php_admin_flag[session.cookie_secure] = off/' \
      /usr/local/hestia/php/etc/php-fpm.conf \
 && sed -i 's/^php_admin_value\[session.cookie_samesite\] = "Strict"/php_admin_value[session.cookie_samesite] = "Lax"/' \
      /usr/local/hestia/php/etc/php-fpm.conf \
 && grep -qE '^php_admin_flag\[session.cookie_secure\] = off' /usr/local/hestia/php/etc/php-fpm.conf

# Expose phpMyAdmin / phpPgAdmin through the panel (so they work via the single
# Umbrel app_proxy port) and make their links work behind the proxy:
#  - add the panel db-admin location blocks to the panel nginx server block;
#  - add the panel nginx user (hestiaweb) to www-data so it can reach the system
#    php pool socket (/run/php/www.sock) that runs phpMyAdmin;
#  - rewrite the DB-list links to be root-relative (stock builds them as
#    "//<host>/phpmyadmin/", and the host is parsed without the proxy port, so
#    the link points at bare :80 / the wrong scheme and 404s).
COPY src/panel-dbadmin.inc /etc/nginx/conf.d/panel-dbadmin.inc
RUN PNG=/usr/local/hestia/nginx/conf/nginx.conf \
 && grep -q panel-dbadmin.inc "$PNG" \
    || sed -i "/server_name *_;/a\\        include /etc/nginx/conf.d/panel-dbadmin.inc;" "$PNG" \
 && usermod -aG www-data hestiaweb \
 && T=/usr/local/hestia/web/templates/pages/list_db.php \
 && sed -i 's#"//" . $http_host . "/#"/#g' "$T" \
 && sed -i 's#"https://".$http_host."/#"/#g' "$T" \
 && grep -q 'panel-dbadmin.inc' "$PNG" \
 && id hestiaweb | grep -q www-data \
 # The File Manager (and "jailbash" SSH access) use HestiaCP's SFTP chroot jail,
 # which bind-mounts each user's home into /srv/jail/<user>. Bind mounts need
 # mount privileges this container doesn't have, so the jail is empty and the
 # File Manager shows no files. Drop the ChrootDirectory line (keeping the
 # "# Hestia SFTP Chroot" comment so v-add-sys-sftp-jail never re-adds it); SFTP
 # then serves each user's real home (ForceCommand internal-sftp -d /home/%u).
 && sed -i '/^[[:space:]]*ChrootDirectory \/srv\/jail\/%u/d' /etc/ssh/sshd_config \
 && ! grep -qE '^[[:space:]]*ChrootDirectory /srv/jail' /etc/ssh/sshd_config

# Snapshot the installed defaults so the entrypoint can seed empty bind-mounted
# data volumes on first run (data then persists under the host's ${APP_DATA_DIR}).
RUN mkdir -p /opt/seed \
 && cp -a /var/lib/mysql          /opt/seed/mysql \
 && cp -a /var/lib/postgresql     /opt/seed/postgresql \
 && cp -a /usr/local/hestia/data  /opt/seed/hestia-data \
 && cp -a /usr/local/hestia/conf  /opt/seed/hestia-conf \
 && cp -a /home                   /opt/seed/home

# Runtime-only scripts last, so editing them doesn't invalidate the install layer.
COPY src/entrypoint.sh /usr/src/entrypoint.sh
COPY src/slim.sh /usr/local/bin/slim.sh
RUN chmod +x /usr/src/entrypoint.sh /usr/local/bin/slim.sh

# FTP fixes for an unprivileged container build:
#  - Hestia chroots FTP users into the SFTP jail (/srv/jail/%u), which needs
#    bind-mount privileges this container doesn't have - the jail is empty and
#    every FTP CWD fails. Chroot to the real home instead (same fix as the
#    File Manager's sshd jail).
#  - The installer bakes pasv_address=<BUILD MACHINE'S public IP> into the
#    config - meaningless (and leaky) in an image. Drop it; the container IP
#    is advertised by default (pasv_promiscuous stays on), and the entrypoint
#    re-adds pasv_address from FTP_PASV_ADDRESS at runtime if set. Hestia
#    already pins the passive range to 12000-12100 (see EXPOSE).
RUN if [ -f /etc/vsftpd.conf ]; then \
      sed -i 's|^local_root=/srv/jail/%u|local_root=/home/%u|; /^pasv_address=/d' /etc/vsftpd.conf \
      && ! grep -q '^pasv_address=' /etc/vsftpd.conf \
      && grep -q '^local_root=/home/%u' /etc/vsftpd.conf; \
    fi

# Disable exim's default DNSBLs (zen.spamhaus.org, bl.spamcop.net) by emptying
# /etc/exim4/dnsbl.conf. Docker/appliance hosts typically resolve through
# public resolvers (1.1.1.1/8.8.8.8), and Spamhaus answers those with an
# "open resolver" error code that exim treats as "listed" - so EVERY inbound
# message gets 550-rejected. RBLs only work with a non-public resolver;
# re-add zones (one per line) to /etc/exim4/dnsbl.conf if you run one. The
# file must stay truly empty otherwise: exim joins its lines verbatim into
# `dnslists` (readfile{...}{:}), so even comment lines would be queried as
# RBL zones. (SpamAssassin/ClamAV are separate and simply not installed.)
RUN if [ -f /etc/exim4/dnsbl.conf ]; then : > /etc/exim4/dnsbl.conf; fi

# panel, hosted sites (HTTP/HTTPS), SSH/SFTP (File Manager), mail
# (SMTP/submission/SMTPS, POP3/POP3S, IMAP/IMAPS), DNS, FTP (+ passive range)
EXPOSE 8083 80 443 22 25 465 587 110 995 143 993 53 53/udp 21 12000-12100

# tini as PID1: proper zombie reaping + signal forwarding for our service set.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/src/entrypoint.sh"]
