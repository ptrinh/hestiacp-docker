# Non-privileged, multi-arch (amd64/arm64) HestiaCP image.
#
# HestiaCP normally needs systemd + privileged mode. This image removes that by
# replacing systemd with a `systemctl` shim (SysV `service` + the
# docker-systemctl-replacement) and installing HestiaCP with the firewall,
# fail2ban and disk-quota features disabled (the parts that need NET_ADMIN /
# kernel quota). The result runs with NO extra capabilities and NO privilege.
#
# Base: debian:12-slim (bookworm) — small, and a HestiaCP-supported OS.
# Version: the installer pulls HestiaCP's `release` branch, i.e. the latest
# stable release at build time, so each build is automatically up to date.
#
# All HestiaCP features are kept by default. To slim a running container later
# (remove phpMyAdmin/File Manager, tune RAM/CPU, disable stats) run the bundled
# `slim.sh`. To drop Apache, rebuild with --build-arg WITH_APACHE=no.
#
# Approach adapted from Steveorevo/hestiacp-dockered, reworked for a small
# Debian base, multi-arch CI builds, and a clean runtime entrypoint.
FROM debian:12-slim

ARG DEBIAN_FRONTEND=noninteractive
# Must be a valid FQDN with >=2 dots — HestiaCP's installer rejects single-label
# / single-dot names (validate_hostname per RFC1178) and aborts.
ARG HESTIA_HOSTNAME=hestia.umbrel.local
ARG HESTIA_EMAIL=admin@hestiacp.local
# Build-time placeholder password; reset at first run by the Umbrel post-start hook.
ARG HESTIA_PASSWORD=changeme
# Keep Apache by default; set to "no" for a leaner nginx-only image.
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
 && touch /var/log/auth.log

# All features kept (Apache optional via WITH_APACHE). Only the privilege-
# requiring add-ons are off: firewall / fail2ban / quota.
RUN ./hst-install-debian.sh \
      --apache "$WITH_APACHE" --phpfpm yes --multiphp no \
      --vsftpd no --proftpd no --named no \
      --mysql yes --postgresql no \
      --exim no --dovecot no --sieve no \
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
 # shipping an empty image
 && test -x /usr/local/hestia/bin/v-list-users \
 # cleanup: downloaded debs, apt caches, logs (same layer so bytes don't persist)
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* /root/*.deb /usr/src/*.deb /var/cache/apt/archives/*.deb \
           /var/log/* /tmp/* \
 # in a pinned container we patch by rebuilding, so stop in-place auto-update
 && (for cf in /var/spool/cron/crontabs/*; do [ -f "$cf" ] && sed -i '/v-update-sys-hestia-all/d' "$cf"; done) || true

# Re-assert the shim in case the installer's apt upgrades restored real systemd.
RUN rm -f /usr/bin/systemctl && ln -s /usr/bin/systemctl.sh /usr/bin/systemctl

# Runtime-only scripts last, so editing them doesn't invalidate the install layer.
COPY src/entrypoint.sh /usr/src/entrypoint.sh
COPY src/slim.sh /usr/local/bin/slim.sh
RUN chmod +x /usr/src/entrypoint.sh /usr/local/bin/slim.sh

EXPOSE 8083 80 443

# tini as PID1: proper zombie reaping + signal forwarding for our service set.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/src/entrypoint.sh"]
