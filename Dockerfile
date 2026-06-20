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
# Approach adapted from Steveorevo/hestiacp-dockered, reworked for a small
# Debian base, multi-arch CI builds, and a clean runtime entrypoint.
FROM debian:12-slim

ARG DEBIAN_FRONTEND=noninteractive
ARG HESTIA_HOSTNAME=hestiacp.local
ARG HESTIA_EMAIL=admin@hestiacp.local
# Build-time placeholder password; reset at first run by the Umbrel post-start hook.
ARG HESTIA_PASSWORD=changeme

RUN apt-get update && apt-get -y upgrade \
 && apt-get install -y --no-install-recommends \
      sudo wget curl ca-certificates git unzip lsb-release php-cli procps \
 && apt-get remove -y apparmor || true \
 && rm -rf /var/lib/apt/lists/*

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
COPY src/start-all-services.sh /usr/src/start-all-services.sh
COPY src/entrypoint.sh /usr/src/entrypoint.sh
RUN chmod +x /usr/src/start-all-services.sh /usr/src/entrypoint.sh

RUN curl -fsSL https://raw.githubusercontent.com/hestiacp/hestiacp/release/install/hst-install-debian.sh \
      -o hst-install-debian.sh \
 && chmod +x hst-install-debian.sh \
 && php /usr/src/patch-hst-install.php /usr/src/hst-install-debian.sh \
 && touch /var/log/auth.log

# Lean, non-privileged feature set: web (nginx+apache+php-fpm), MariaDB, API.
# Firewall / fail2ban / quota disabled (need privilege). Mail/DNS/FTP can be
# enabled later by flipping the flags below.
RUN ./hst-install-debian.sh \
      --apache yes --phpfpm yes --multiphp no \
      --vsftpd no --proftpd no --named no \
      --mysql yes --postgresql no \
      --exim no --dovecot no --sieve no \
      --clamav no --spamassassin no \
      --iptables no --fail2ban no --quota no \
      --api yes --with-debs no \
      --port 8083 \
      --hostname "$HESTIA_HOSTNAME" \
      --email "$HESTIA_EMAIL" \
      --password "$HESTIA_PASSWORD" \
      --lang en --force --interactive no \
 && rm -rf /var/lib/apt/lists/*

# Re-assert the shim in case the installer's apt upgrades restored real systemd.
RUN rm -f /usr/bin/systemctl && ln -s /usr/bin/systemctl.sh /usr/bin/systemctl

EXPOSE 8083 80 443

ENTRYPOINT ["/usr/src/entrypoint.sh"]
