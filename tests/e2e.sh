#!/usr/bin/env bash
# End-to-end test for the HestiaCP image / Umbrel package.
#
# Drives the panel exactly like a browser (curl + cookie jar + CSRF tokens):
#   1. login page renders (not a PHP fatal)
#   2. login flow with admin credentials -> authenticated session
#   3. create a hosting user account
#   4. add a web domain (admin flow, past the "use a standard user" warning)
#   5. hosted site actually serves the domain's docroot on the published port
#   6. (optional) restart the app and verify panel + site recover
#
# Mail/DNS/FTP are NOT tested: this build is scoped to web hosting, databases
# and the File Manager (see Dockerfile header) and does not ship those daemons.
#
# NOTE: Hestia HTML-encodes output ("." becomes "&period;"), so every page is
# entity-decoded before matching.
#
# Usage:
#   PANEL_URL=http://192.168.1.91:8084 \
#   SITE_URL=http://192.168.1.91:9088 \
#   ADMIN_PASSWORD=... \
#   [RESTART_CMD='ssh umbrel@192.168.1.91 "umbreld client apps.restart.mutate --appId trinh-hestiacp-np"'] \
#   ./tests/e2e.sh
#
# For a plain docker run:  PANEL_URL=https://localhost:18083 SITE_URL=http://localhost:18088 ...
set -uo pipefail

PANEL_URL="${PANEL_URL:?set PANEL_URL, e.g. http://umbrel-host:8084}"
SITE_URL="${SITE_URL:?set SITE_URL, e.g. http://umbrel-host:9088}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:?set ADMIN_PASSWORD}"
RESTART_CMD="${RESTART_CMD:-}"
TEST_USER="${TEST_USER:-e2etest}"
TEST_DOMAIN="${TEST_DOMAIN:-e2etest.example.com}"

JAR="$(mktemp)"
trap 'rm -f "$JAR"' EXIT
CURL=(curl -ks --cookie "$JAR" --cookie-jar "$JAR" --max-time 30)

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  PASS: $*"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $*"; }

# Hestia entity-encodes its HTML output; decode enough to grep for domains/IPs.
decode() { sed -e 's/&period;/./g' -e 's/&equals;/=/g' -e 's/&amp;/\&/g' -e 's/&quest;/?/g'; }

# Fetch a page and extract the CSRF token Hestia embeds as
# <input type="hidden" name="token" value="...">
get_token() {
  "${CURL[@]}" "$1" | grep -oE 'name="token" value="[a-f0-9]+"' | grep -oE '[a-f0-9]{16,}' | head -1
}

login() {
  local tok
  tok="$(get_token "$PANEL_URL/login/")"
  "${CURL[@]}" -o /dev/null "$PANEL_URL/login/" \
    --data-urlencode "user=$ADMIN_USER" \
    --data-urlencode "password=$ADMIN_PASSWORD" \
    --data-urlencode "token=$tok"
}

# Authenticated GET; re-logins if the panel dropped the session (panel actions
# can restart Hestia's backend, which invalidates sessions and can briefly 502).
fetch_auth() {
  local out attempt
  for attempt in 1 2 3; do
    out="$("${CURL[@]}" "$1" | decode)"
    echo "$out" | grep -q "/logout" && break
    sleep 3
    login
  done
  printf '%s' "$out" | tee /tmp/e2e-last-fetch.html
}

echo "== 1. login page renders"
body="$("${CURL[@]}" "$PANEL_URL/login/")"
if echo "$body" | grep -qi 'Unable to load required libraries'; then
  fail "login page shows PHP fatal (vendor deps missing)"
elif echo "$body" | grep -q 'name="user"'; then
  ok "login form present"
else
  fail "login form not found"; echo "$body" | head -5
fi

echo "== 2. login flow"
tok="$(get_token "$PANEL_URL/login/")"
[ -n "$tok" ] && ok "got CSRF token" || fail "no CSRF token on login page"
login
home="$("${CURL[@]}" "$PANEL_URL/list/user/" | decode)"
if echo "$home" | grep -q "/logout"; then
  ok "authenticated session established (user list reachable)"
else
  fail "login did not produce an authenticated session"
fi

echo "== 3. create hosting user '$TEST_USER'"
if echo "$home" | grep -q "user=$TEST_USER"; then
  ok "user already exists (previous run) - continuing"
else
  tok="$(get_token "$PANEL_URL/add/user/")"
  "${CURL[@]}" -o /dev/null "$PANEL_URL/add/user/" \
    --data-urlencode "ok=Add" \
    --data-urlencode "v_username=$TEST_USER" \
    --data-urlencode "v_password=E2e-$(head -c16 /dev/urandom | base64 | tr -dc A-Za-z0-9 | head -c 12)1!" \
    --data-urlencode "v_email=e2e@example.com" \
    --data-urlencode "v_name=E2E Test" \
    --data-urlencode "v_package=default" \
    --data-urlencode "v_language=en" \
    --data-urlencode "v_role=user" \
    --data-urlencode "v_notify=on" \
    --data-urlencode "token=$tok"
  ucreated=0
  for _ in $(seq 1 12); do
    fetch_auth "$PANEL_URL/list/user/" | grep -q "user=$TEST_USER" && { ucreated=1; break; }
    sleep 5
  done
  if [ "$ucreated" = 1 ]; then
    ok "user created"
  else
    fail "user not visible after add"
    echo "  (debug) last page title: $(grep -oE '<title>[^<]*' /tmp/e2e-last-fetch.html 2>/dev/null | head -1)"
  fi
fi

echo "== 4. add web domain '$TEST_DOMAIN' (admin flow)"
domlist="$(fetch_auth "$PANEL_URL/list/web/")"
if echo "$domlist" | grep -q "$TEST_DOMAIN"; then
  ok "domain already exists (previous run) - continuing"
else
  # /add/web/ shows a "create a standard user first" interstitial for admin;
  # the real form is behind ?accept=true and needs v_ip (the system IP).
  page="$("${CURL[@]}" "$PANEL_URL/add/web/?accept=true" | decode)"
  tok="$(echo "$page" | grep -oE 'name="token" value="[a-f0-9]+"' | grep -oE '[a-f0-9]{16,}' | head -1)"
  ip="$(echo "$page" | grep -oE 'value="([0-9]{1,3}\.){3}[0-9]{1,3}"' | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)"
  if [ -z "$ip" ]; then
    fail "no system IP offered on add/web form (IP registration failed?)"
  else
    ok "system IP offered: $ip"
    "${CURL[@]}" -o /dev/null "$PANEL_URL/add/web/?accept=true" \
      --data-urlencode "ok=Add" \
      --data-urlencode "v_domain=$TEST_DOMAIN" \
      --data-urlencode "v_ip=$ip" \
      --data-urlencode "token=$tok"
    # the first domain add restarts the web stack and can take a while
    found=0
    for _ in $(seq 1 36); do
      fetch_auth "$PANEL_URL/list/web/" | grep -q "$TEST_DOMAIN" && { found=1; break; }
      sleep 5
    done
    [ "$found" = 1 ] && ok "domain listed in panel" || fail "domain not listed after add"
  fi
fi

echo "== 5. hosted site serves on $SITE_URL"
# The domain's docroot gets Hestia's per-domain default page, which contains
# the domain name; a random Host hits the server default page, which doesn't.
served=0
for _ in $(seq 1 18); do
  page="$(curl -ks --max-time 10 -H "Host: $TEST_DOMAIN" "$SITE_URL/" | decode)"
  echo "$page" | grep -qi "$TEST_DOMAIN" && { served=1; break; }
  sleep 5
done
if [ "$served" = 1 ]; then
  ok "site serves the domain's own page for Host: $TEST_DOMAIN"
else
  fail "site did not serve the domain page (default/catch-all only)"
fi

if [ -n "$RESTART_CMD" ]; then
  echo "== 6. restart recovery"
  echo "  restarting via: $RESTART_CMD"
  if eval "$RESTART_CMD" >/dev/null 2>&1; then
    panel_ok=0; site_ok=0
    for _ in $(seq 1 60); do  # up to 10 min
      curl -ks --max-time 10 "$PANEL_URL/login/" | grep -q 'name="user"' && { panel_ok=1; break; }
      sleep 10
    done
    [ "$panel_ok" = 1 ] && ok "panel back after restart" || fail "panel did not come back"
    for _ in $(seq 1 30); do  # up to 5 min for the on-start rebuild
      curl -ks --max-time 10 -H "Host: $TEST_DOMAIN" "$SITE_URL/" | decode | grep -qi "$TEST_DOMAIN" && { site_ok=1; break; }
      sleep 10
    done
    [ "$site_ok" = 1 ] && ok "hosted site back after restart" || fail "hosted site did not recover"
  else
    fail "restart command failed"
  fi
else
  echo "== 6. restart recovery: SKIPPED (set RESTART_CMD to enable)"
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
