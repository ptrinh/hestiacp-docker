#!/usr/bin/env bash
# End-to-end test for the HestiaCP image / Umbrel package.
#
# Drives the panel exactly like a browser (curl + cookie jar + CSRF tokens):
#    1. login page renders (not a PHP fatal)
#    2. login flow with admin credentials -> authenticated session
#    3. create a hosting user account (recreated fresh if left from a prior run)
#    4. add a web domain as admin (past the "use a standard user" warning)
#    5. hosted site serves the domain's docroot on the published HTTP port
#    6. databases: create MariaDB + PostgreSQL DBs via the panel;
#       phpMyAdmin / phpPgAdmin render through the panel proxy
#    7. File Manager: create + upload files into the docroot over the FM API
#    8. PHP executes on the hosted site (and connects to the DBs from step 6)
#    9. HTTPS hosted-site port completes a TLS handshake and serves;
#       best-effort: enable a self-signed cert on the domain and check SNI
#   10. hosting user can log in and host their own domain
#   11. cron: a panel-created job runs and its output is served by the site
#   12. mail: create a mail domain + mailbox, deliver a message over SMTP,
#       read it back over IMAP  (skipped when mail isn't built into the image)
#   13. DNS: create a zone in the panel, query it with dig  (needs dig)
#   14. FTP: log in with the hosting user, upload into the docroot, fetch the
#       file through the hosted site
#   15. backup: a scheduled backup appears in the panel  (SKIP_SLOW=1 skips)
#   16. restart recovery: panel + site + PHP survive an app restart  (RESTART_CMD)
#   17. update simulation: same, across an image update  (UPDATE_CMD)
#   18. resource snapshot, informational  (STATS_CMD)
#
# NOTE: Hestia HTML-encodes output ("." becomes "&period;"), so every page is
# entity-decoded before matching.
#
# Usage:
#   PANEL_URL=http://192.168.1.91:8084 \
#   SITE_URL=http://192.168.1.91:9088 \
#   SITE_SSL_URL=https://192.168.1.91:9448 \
#   ADMIN_PASSWORD=... \
#   [RESTART_CMD='ssh umbrel@... "umbreld client apps.restart.mutate --appId trinh-hestiacp-np"'] \
#   [UPDATE_CMD='...recreate the container with a newer image...'] \
#   [STATS_CMD='docker stats --no-stream hestia-e2e'] \
#   [SKIP_SLOW=1] \
#   [SVC_HOST=192.168.1.91 SMTP_PORT=25 IMAP_PORT=143 DNS_PORT=53 FTP_PORT=21] \
#   ./tests/e2e.sh
#
# For a plain docker run:  PANEL_URL=https://localhost:18083 SITE_URL=http://localhost:18088 \
#                          SITE_SSL_URL=https://localhost:18448 ...
set -uo pipefail

PANEL_URL="${PANEL_URL:?set PANEL_URL, e.g. http://umbrel-host:8084}"
SITE_URL="${SITE_URL:?set SITE_URL, e.g. http://umbrel-host:9088}"
SITE_SSL_URL="${SITE_SSL_URL:-}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:?set ADMIN_PASSWORD}"
RESTART_CMD="${RESTART_CMD:-}"
UPDATE_CMD="${UPDATE_CMD:-}"
STATS_CMD="${STATS_CMD:-}"
SKIP_SLOW="${SKIP_SLOW:-}"
TEST_USER="${TEST_USER:-e2etest}"
TEST_DOMAIN="${TEST_DOMAIN:-e2etest.example.com}"
USER_DOMAIN="${USER_DOMAIN:-e2euser.example.com}"
DB_PASS="E2eDbPass-$(date +%s)x1"
TEST_USER_PW="E2eUserPass-$(date +%s)y2"
MAIL_PW="E2eMailPass-$(date +%s)z3"
# host to reach the raw service ports on (mail/DNS/FTP); default: SITE_URL's host
_svc="${SITE_URL#*://}"; _svc="${_svc%%/*}"; _svc="${_svc%%:*}"
SVC_HOST="${SVC_HOST:-$_svc}"
SMTP_PORT="${SMTP_PORT:-25}"
IMAP_PORT="${IMAP_PORT:-143}"
DNS_PORT="${DNS_PORT:-53}"
FTP_PORT="${FTP_PORT:-21}"

JAR="$(mktemp)"
UJAR="$(mktemp)"
TMPD="$(mktemp -d)"
trap 'rm -rf "$JAR" "$UJAR" "$TMPD"' EXIT
CURL=(curl -ks --cookie "$JAR" --cookie-jar "$JAR" --max-time 30)
UCURL=(curl -ks --cookie "$UJAR" --cookie-jar "$UJAR" --max-time 30)

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); echo "  PASS: $*"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $*"; }
skip() { SKIP=$((SKIP+1)); echo "  SKIP: $*"; }

# Hestia entity-encodes its HTML output; decode enough to grep for domains/IPs.
decode() { sed -e 's/&period;/./g' -e 's/&equals;/=/g' -e 's/&amp;/\&/g' -e 's/&quest;/?/g' -e 's/&lowbar;/_/g'; }

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

# The File Manager (FileGator) API lives at /fm/?r=/<route>; every response
# carries a rotating x-csrf-token header that the next request must echo.
fm_csrf() {
  "${CURL[@]}" -o /dev/null -D - "$PANEL_URL/fm/" | grep -i '^x-csrf-token' | awk '{print $2}' | tr -d '\r'
}

site_php() {  # fetch the uploaded PHP probe through the hosted site
  curl -ks --max-time 10 -H "Host: $TEST_DOMAIN" "$SITE_URL/e2e-probe.php"
}

get_sys_ip() {  # the system IP Hestia currently offers (= the container IP)
  local ip
  for _ in 1 2 3 4; do
    ip="$(fetch_auth "$PANEL_URL/add/web/?accept=true" \
      | grep -oE 'value="([0-9]{1,3}\.){3}[0-9]{1,3}"' \
      | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)"
    [ -n "$ip" ] && break
    sleep 5
  done
  printf '%s' "$ip"
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
  # left over from a previous run and we don't know its password - recreate
  tok="$(get_token "$PANEL_URL/list/user/")"
  "${CURL[@]}" -o /dev/null "$PANEL_URL/delete/user/?user=$TEST_USER&token=$tok"
  for _ in $(seq 1 12); do
    fetch_auth "$PANEL_URL/list/user/" | grep -q "user=$TEST_USER" || break
    sleep 5
  done
  echo "  (recreating user left over from a previous run)"
fi
tok="$(get_token "$PANEL_URL/add/user/")"
"${CURL[@]}" -o /dev/null "$PANEL_URL/add/user/" \
  --data-urlencode "ok=Add" \
  --data-urlencode "v_username=$TEST_USER" \
  --data-urlencode "v_password=$TEST_USER_PW" \
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

echo "== 6. databases (MariaDB + PostgreSQL) and web DB admins"
dblist="$(fetch_auth "$PANEL_URL/list/db/")"
add_db() {  # $1=short name  $2=type  $3=charset
  if echo "$dblist" | grep -q "${ADMIN_USER}_$1"; then
    echo "  (db ${ADMIN_USER}_$1 already exists - continuing)"
    return 0
  fi
  local tok
  tok="$(get_token "$PANEL_URL/add/db/?accept=true")"
  "${CURL[@]}" -o /dev/null "$PANEL_URL/add/db/?accept=true" \
    --data-urlencode "ok=Add" \
    --data-urlencode "v_database=$1" \
    --data-urlencode "v_dbuser=$1" \
    --data-urlencode "v_password=$DB_PASS" \
    --data-urlencode "v_type=$2" \
    --data-urlencode "v_host=localhost" \
    --data-urlencode "v_charset=$3" \
    --data-urlencode "token=$tok"
}
add_db e2emy mysql utf8mb4
add_db e2epg pgsql UTF8
dbok=0
for _ in $(seq 1 12); do
  dblist="$(fetch_auth "$PANEL_URL/list/db/")"
  if echo "$dblist" | grep -q "${ADMIN_USER}_e2emy" && echo "$dblist" | grep -q "${ADMIN_USER}_e2epg"; then
    dbok=1; break
  fi
  sleep 5
done
[ "$dbok" = 1 ] && ok "MariaDB and PostgreSQL databases created and listed" \
                || fail "databases not listed after add"
pma="$("${CURL[@]}" "$PANEL_URL/phpmyadmin/")"
echo "$pma" | grep -qi "phpmyadmin" && ok "phpMyAdmin renders through the panel" \
                                     || fail "phpMyAdmin did not render"
ppa="$("${CURL[@]}" "$PANEL_URL/phppgadmin/")"
echo "$ppa" | grep -qi "phppgadmin" && ok "phpPgAdmin renders through the panel" \
                                     || fail "phpPgAdmin did not render"

echo "== 7. File Manager API (create + upload into the docroot)"
DOCROOT="/web/$TEST_DOMAIN/public_html"
# FileGator's createnew writes into the SESSION cwd (it ignores any
# destination parameter), so change directory first.
"${CURL[@]}" -o /dev/null -X POST "$PANEL_URL/fm/?r=/changedir" \
  -H "x-csrf-token: $(fm_csrf)" -H "Content-Type: application/json" \
  -d "{\"to\":\"$DOCROOT\"}"
resp="$("${CURL[@]}" -X POST "$PANEL_URL/fm/?r=/createnew" \
  -H "x-csrf-token: $(fm_csrf)" -H "Content-Type: application/json" \
  -d '{"type":"file","name":"fm-ok.txt"}')"
if echo "$resp" | grep -q "Done"; then
  ok "File Manager created a file in the docroot"
else
  fail "File Manager createnew failed: $(echo "$resp" | head -c 120)"
fi
# upload a PHP probe (FileGator upload = resumable.js single chunk, cd = dir)
cat > "$TMPD/e2e-probe.php" <<PHPEOF
<?php
echo "PHP_OK:", 2 + 5, ";";
if (function_exists('mysqli_connect')) {
    \$m = @mysqli_connect('localhost', '${ADMIN_USER}_e2emy', '$DB_PASS', '${ADMIN_USER}_e2emy');
    echo \$m ? "MYSQL_OK;" : "MYSQL_FAIL;";
} else { echo "MYSQL_SKIP;"; }
if (function_exists('pg_connect')) {
    \$p = @pg_connect('host=localhost dbname=${ADMIN_USER}_e2epg user=${ADMIN_USER}_e2epg password=$DB_PASS');
    echo \$p ? "PG_OK;" : "PG_FAIL;";
} else { echo "PG_SKIP;"; }
PHPEOF
sz=$(wc -c < "$TMPD/e2e-probe.php" | tr -d ' ')
# FileGator's upload reads the DESTINATION DIRECTORY from resumableRelativePath.
up="$("${CURL[@]}" -X POST "$PANEL_URL/fm/?r=/upload" \
  -H "x-csrf-token: $(fm_csrf)" \
  -F "resumableChunkNumber=1" -F "resumableTotalChunks=1" \
  -F "resumableChunkSize=1048576" -F "resumableCurrentChunkSize=$sz" \
  -F "resumableTotalSize=$sz" \
  -F "resumableIdentifier=e2eprobe$$" -F "resumableFilename=e2e-probe.php" \
  -F "resumableRelativePath=$DOCROOT" \
  -F "file=@$TMPD/e2e-probe.php;filename=e2e-probe.php")"
# verify both artifacts through the web server, not just the API reply
fmok=0
for _ in $(seq 1 6); do
  code="$(curl -ks -o /dev/null -w '%{http_code}' --max-time 10 -H "Host: $TEST_DOMAIN" "$SITE_URL/fm-ok.txt")"
  [ "$code" = "200" ] && { fmok=1; break; }
  sleep 5
done
[ "$fmok" = 1 ] && ok "created file is served by the site (200)" \
               || fail "created file not served (last http $code; upload said: $(echo "$up" | head -c 80))"

echo "== 8. PHP executes on the hosted site (and reaches the databases)"
phpout=""
for _ in $(seq 1 6); do
  phpout="$(site_php)"
  echo "$phpout" | grep -q "PHP_OK:7" && break
  sleep 5
done
if echo "$phpout" | grep -q "PHP_OK:7"; then
  ok "PHP executes in the domain's pool"
else
  fail "PHP did not execute: $(echo "$phpout" | head -c 120)"
fi
case "$phpout" in
  *MYSQL_OK*)   ok "PHP connected to MariaDB with the created credentials" ;;
  *MYSQL_SKIP*) skip "mysqli extension not present in web PHP" ;;
  *)            fail "PHP could not connect to MariaDB" ;;
esac
case "$phpout" in
  *PG_OK*)   ok "PHP connected to PostgreSQL with the created credentials" ;;
  *PG_SKIP*) skip "pgsql extension not present in web PHP" ;;
  *)         fail "PHP could not connect to PostgreSQL" ;;
esac

echo "== 9. HTTPS hosted-site port"
if [ -z "$SITE_SSL_URL" ]; then
  skip "SITE_SSL_URL not set"
else
  code="$(curl -ks -o /dev/null -w '%{http_code}' --max-time 10 "$SITE_SSL_URL/" )"
  if [ "$code" != "000" ]; then
    ok "HTTPS port completes TLS handshake and answers (http $code)"
  else
    fail "HTTPS port did not answer"
  fi
  # enable a self-signed cert on the test domain, then check SNI. The edit
  # form must be submitted IN FULL (like a browser would) or the handler
  # PHP-fatals on missing keys, so serialize every field from the page and
  # override just the SSL ones.
  if command -v openssl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    cat > "$TMPD/formser.py" <<'PYEOF'
import sys
from html.parser import HTMLParser
from urllib.parse import urlencode

class F(HTMLParser):
    def __init__(self):
        super().__init__(); self.fields={}; self.insel=None; self.intext=None; self.buf=''
    def handle_starttag(self, tag, attrs):
        a=dict(attrs)
        if tag=='input':
            n=a.get('name'); t=a.get('type','text')
            if not n: return
            if t in ('checkbox','radio'):
                if 'checked' in a: self.fields[n]=a.get('value','on')
            elif t not in ('submit','button','file'):
                self.fields[n]=a.get('value','')
        elif tag=='select':
            self.insel=a.get('name'); self.fields.setdefault(self.insel,'')
        elif tag=='option' and self.insel:
            if 'selected' in a: self.fields[self.insel]=a.get('value','')
            elif self.fields.get(self.insel)=='': self.fields.setdefault(self.insel, a.get('value',''))
        elif tag=='textarea':
            self.intext=a.get('name'); self.buf=''
    def handle_endtag(self, tag):
        if tag=='select': self.insel=None
        elif tag=='textarea' and self.intext:
            self.fields[self.intext]=self.buf.strip(); self.intext=None
    def handle_data(self, d):
        if self.intext is not None: self.buf+=d

html=sys.stdin.read()
for a,b in (('&period;','.'),('&equals;','='),('&amp;','&'),('&quest;','?'),('&lowbar;','_')):
    html=html.replace(a,b)
p=F(); p.feed(html)
for arg in sys.argv[1:]:
    k,v=arg.split('=',1)
    if v.startswith('@'): v=open(v[1:]).read()
    p.fields[k]=v
print(urlencode(p.fields))
PYEOF
    openssl req -x509 -newkey rsa:2048 -keyout "$TMPD/k.pem" -out "$TMPD/c.pem" \
      -days 30 -nodes -subj "/CN=$TEST_DOMAIN" >/dev/null 2>&1
    # v_proxy is an Alpine.js x-model checkbox (no checked attribute in the
    # HTML), so the serializer can't see its ON state - pass it explicitly or
    # the save would strip the nginx proxy vhost from the domain.
    "${CURL[@]}" "$PANEL_URL/edit/web/?domain=$TEST_DOMAIN" \
      | python3 "$TMPD/formser.py" "save=Save" "v_ssl=on" \
          "v_proxy=on" "v_proxy_ext=jpg,jpeg,gif,png,ico,svg,css,zip,rar,js" \
          "v_ssl_crt=@$TMPD/c.pem" "v_ssl_key=@$TMPD/k.pem" > "$TMPD/sslbody.txt"
    "${CURL[@]}" -o /dev/null "$PANEL_URL/edit/web/?domain=$TEST_DOMAIN" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      --data-binary "@$TMPD/sslbody.txt"
    sslok=0
    for _ in $(seq 1 18); do
      subj="$(echo | openssl s_client -connect "${SITE_SSL_URL#https://}" \
                -servername "$TEST_DOMAIN" 2>/dev/null | openssl x509 -noout -subject 2>/dev/null)"
      echo "$subj" | grep -q "$TEST_DOMAIN" && { sslok=1; break; }
      sleep 5
    done
    if [ "$sslok" = 1 ]; then
      ok "per-domain self-signed cert is served via SNI"
    else
      fail "per-domain SSL not served via SNI (subj: ${subj:-none})"
    fi
  else
    skip "openssl/python3 not available for per-domain SSL test"
  fi
fi

echo "== 10. hosting user can log in and host a domain"
utok="$("${UCURL[@]}" "$PANEL_URL/login/" | grep -oE 'name="token" value="[a-f0-9]+"' | grep -oE '[a-f0-9]{16,}' | head -1)"
"${UCURL[@]}" -o /dev/null "$PANEL_URL/login/" \
  --data-urlencode "user=$TEST_USER" \
  --data-urlencode "password=$TEST_USER_PW" \
  --data-urlencode "token=$utok"
uhome="$("${UCURL[@]}" "$PANEL_URL/list/web/" | decode)"
if echo "$uhome" | grep -q "/logout"; then
  ok "hosting user logged in"
  if ! echo "$uhome" | grep -q "$USER_DOMAIN"; then
    upage="$("${UCURL[@]}" "$PANEL_URL/add/web/" | decode)"
    utok="$(echo "$upage" | grep -oE 'name="token" value="[a-f0-9]+"' | grep -oE '[a-f0-9]{16,}' | head -1)"
    uip="$(echo "$upage" | grep -oE 'value="([0-9]{1,3}\.){3}[0-9]{1,3}"' | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)"
    "${UCURL[@]}" -o /dev/null "$PANEL_URL/add/web/" \
      --data-urlencode "ok=Add" \
      --data-urlencode "v_domain=$USER_DOMAIN" \
      --data-urlencode "v_ip=${uip:-}" \
      --data-urlencode "token=$utok"
  fi
  uok=0
  for _ in $(seq 1 24); do
    upg="$(curl -ks --max-time 10 -H "Host: $USER_DOMAIN" "$SITE_URL/" | decode)"
    echo "$upg" | grep -qi "$USER_DOMAIN" && { uok=1; break; }
    sleep 5
  done
  [ "$uok" = 1 ] && ok "user-owned domain serves its own page" \
                || fail "user-owned domain not served"
else
  fail "hosting user could not log in"
fi

echo "== 11. cron job runs and output is served"
cronlist="$(fetch_auth "$PANEL_URL/list/cron/")"
if ! echo "$cronlist" | grep -q "cron-ok"; then
  tok="$(get_token "$PANEL_URL/add/cron/")"
  "${CURL[@]}" -o /dev/null "$PANEL_URL/add/cron/" \
    --data-urlencode "ok=Add" \
    --data-urlencode "v_min=*" --data-urlencode "v_hour=*" \
    --data-urlencode "v_day=*" --data-urlencode "v_month=*" \
    --data-urlencode "v_wday=*" \
    --data-urlencode "v_cmd=touch /home/$ADMIN_USER/web/$TEST_DOMAIN/public_html/cron-ok.txt" \
    --data-urlencode "token=$tok"
fi
cronok=0
for _ in $(seq 1 36); do  # cron granularity is 1 min; allow up to 3 min
  code="$(curl -ks -o /dev/null -w '%{http_code}' --max-time 10 -H "Host: $TEST_DOMAIN" "$SITE_URL/cron-ok.txt")"
  [ "$code" = "200" ] && { cronok=1; break; }
  sleep 5
done
[ "$cronok" = 1 ] && ok "cron job ran and its artifact is served (200)" \
                 || fail "cron artifact never appeared (last http $code)"

echo "== 12. mail: SMTP delivery -> IMAP read"
maillist="$(fetch_auth "$PANEL_URL/list/mail/")"
if ! echo "$maillist" | grep -qE '<title>MAIL'; then
  skip "panel has no mail section (mail not built into this image)"
else
  if ! echo "$maillist" | grep -q "$TEST_DOMAIN"; then
    tok="$(get_token "$PANEL_URL/add/mail/")"
    "${CURL[@]}" -o /dev/null "$PANEL_URL/add/mail/" \
      --data-urlencode "ok=Add" \
      --data-urlencode "v_domain=$TEST_DOMAIN" \
      --data-urlencode "token=$tok"
  fi
  mdok=0
  for _ in $(seq 1 12); do
    fetch_auth "$PANEL_URL/list/mail/" | grep -q "$TEST_DOMAIN" && { mdok=1; break; }
    sleep 5
  done
  [ "$mdok" = 1 ] && ok "mail domain created" || fail "mail domain not listed after add"
  # mailbox e2e@$TEST_DOMAIN (form trigger is ok_acc on the same page)
  acclist="$(fetch_auth "$PANEL_URL/list/mail/?domain=$TEST_DOMAIN")"
  if ! echo "$acclist" | grep -q "account=e2e"; then
    tok="$(get_token "$PANEL_URL/add/mail/?domain=$TEST_DOMAIN")"
    "${CURL[@]}" -o /dev/null "$PANEL_URL/add/mail/?domain=$TEST_DOMAIN" \
      --data-urlencode "ok_acc=Add" \
      --data-urlencode "v_domain=$TEST_DOMAIN" \
      --data-urlencode "v_account=e2e" \
      --data-urlencode "v_password=$MAIL_PW" \
      --data-urlencode "v_quota=" \
      --data-urlencode "token=$tok"
  fi
  # deliver a message over SMTP (we are the MX for the domain). Exim verifies
  # that the SENDER's domain is routable, so it must be a real domain.
  MAIL_SENDER="${MAIL_SENDER:-ext@gmail.com}"
  MARK="e2e-mail-$$-$(date +%s)"
  printf 'From: %s\nTo: e2e@%s\nSubject: %s\n\ntest body\n' \
    "$MAIL_SENDER" "$TEST_DOMAIN" "$MARK" > "$TMPD/msg.txt"
  smtpok=0
  for _ in $(seq 1 6); do
    curl -s --max-time 20 "smtp://$SVC_HOST:$SMTP_PORT" \
      --mail-from "$MAIL_SENDER" --mail-rcpt "e2e@$TEST_DOMAIN" \
      -T "$TMPD/msg.txt" && { smtpok=1; break; }
    sleep 10
  done
  [ "$smtpok" = 1 ] && ok "SMTP accepted a message for e2e@$TEST_DOMAIN" \
                   || fail "SMTP delivery was refused"
  # read it back over IMAP (login is the full address)
  imapok=0
  for _ in $(seq 1 18); do
    curl -s --max-time 20 --url "imap://$SVC_HOST:$IMAP_PORT/INBOX" \
      -u "e2e@$TEST_DOMAIN:$MAIL_PW" -X "SEARCH SUBJECT $MARK" 2>/dev/null \
      | grep -qE 'SEARCH [0-9]' && { imapok=1; break; }
    sleep 10
  done
  [ "$imapok" = 1 ] && ok "IMAP login works and the message arrived in INBOX" \
                   || fail "message never appeared over IMAP"
fi

echo "== 13. DNS zone served on port $DNS_PORT"
dnslist="$(fetch_auth "$PANEL_URL/list/dns/")"
if ! echo "$dnslist" | grep -qE '<title>DNS'; then
  skip "panel has no DNS section (DNS not built into this image)"
elif ! command -v dig >/dev/null 2>&1; then
  skip "dig not available"
else
  if ! echo "$dnslist" | grep -q "$TEST_DOMAIN"; then
    page="$("${CURL[@]}" "$PANEL_URL/add/dns/?accept=true" | decode)"
    tok="$(echo "$page" | grep -oE 'name="token" value="[a-f0-9]+"' | grep -oE '[a-f0-9]{16,}' | head -1)"
    dip="$(echo "$page" | grep -oE 'value="([0-9]{1,3}\.){3}[0-9]{1,3}"' | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)"
    "${CURL[@]}" -o /dev/null "$PANEL_URL/add/dns/?accept=true" \
      --data-urlencode "ok=Add" \
      --data-urlencode "v_domain=$TEST_DOMAIN" \
      --data-urlencode "v_ip=$dip" \
      --data-urlencode "token=$tok"
  fi
  digok=0
  for _ in $(seq 1 12); do
    soa="$(dig +short +time=3 +tries=1 -p "$DNS_PORT" "@$SVC_HOST" "$TEST_DOMAIN" SOA 2>/dev/null)"
    [ -n "$soa" ] && { digok=1; break; }
    sleep 5
  done
  if [ "$digok" = 1 ]; then
    ok "authoritative SOA answer for $TEST_DOMAIN"
    arec="$(dig +short +time=3 +tries=1 -p "$DNS_PORT" "@$SVC_HOST" "www.$TEST_DOMAIN" A 2>/dev/null)"
    [ -n "$arec" ] && ok "A record for www.$TEST_DOMAIN resolves ($arec)" \
                  || fail "www A record did not resolve"
  else
    fail "no SOA answer from bind on $SVC_HOST:$DNS_PORT"
  fi
fi

echo "== 14. FTP login + upload served by the site"
ftpprobe="$(curl -s --max-time 20 --ftp-skip-pasv-ip "ftp://$SVC_HOST:$FTP_PORT/" \
             -u "$TEST_USER:$TEST_USER_PW" -l 2>&1)"
if echo "$ftpprobe" | grep -qiE "couldn.t connect|connection refused|timed out"; then
  skip "FTP port not reachable (FTP not built into this image or port unpublished)"
elif [ -z "$ftpprobe" ] || echo "$ftpprobe" | grep -qiE "access denied|login"; then
  fail "FTP login failed for $TEST_USER: $(echo "$ftpprobe" | head -c 100)"
else
  ok "FTP login works and lists the home directory"
  echo "ftp-upload-ok" > "$TMPD/ftp-ok.txt"
  if curl -s --max-time 30 --ftp-skip-pasv-ip -T "$TMPD/ftp-ok.txt" \
       -u "$TEST_USER:$TEST_USER_PW" \
       "ftp://$SVC_HOST:$FTP_PORT/web/$USER_DOMAIN/public_html/ftp-ok.txt"; then
    ftpok=0
    for _ in $(seq 1 6); do
      curl -ks --max-time 10 -H "Host: $USER_DOMAIN" "$SITE_URL/ftp-ok.txt" \
        | grep -q "ftp-upload-ok" && { ftpok=1; break; }
      sleep 5
    done
    [ "$ftpok" = 1 ] && ok "FTP-uploaded file is served by the hosted site" \
                    || fail "FTP-uploaded file not served"
  else
    fail "FTP upload failed"
  fi
fi

echo "== 15. backup"
if [ -n "$SKIP_SLOW" ]; then
  skip "SKIP_SLOW set"
else
  blist="$(fetch_auth "$PANEL_URL/list/backup/")"
  if echo "$blist" | grep -qE "${ADMIN_USER}\.[0-9]{4}"; then
    ok "backup already listed (previous run)"
  else
    tok="$(get_token "$PANEL_URL/list/backup/")"
    "${CURL[@]}" -o /dev/null "$PANEL_URL/schedule/backup/?token=$tok"
    bok=0
    for _ in $(seq 1 60); do  # backups run from the queue; allow up to 10 min
      fetch_auth "$PANEL_URL/list/backup/" | grep -qE "${ADMIN_USER}\.[0-9]{4}" && { bok=1; break; }
      sleep 10
    done
    [ "$bok" = 1 ] && ok "scheduled backup completed and is listed" \
                  || fail "backup never appeared in the panel"
  fi
fi

verify_recovery() {  # $1 = phase label
  local panel_ok=0 site_ok=0 php_ok=0 code
  for _ in $(seq 1 60); do  # up to 10 min
    curl -ks --max-time 10 "$PANEL_URL/login/" | grep -q 'name="user"' && { panel_ok=1; break; }
    sleep 10
  done
  [ "$panel_ok" = 1 ] && ok "panel back after $1" || fail "panel did not come back after $1"
  for _ in $(seq 1 30); do  # up to 5 min for the on-start rebuild
    curl -ks --max-time 10 -H "Host: $TEST_DOMAIN" "$SITE_URL/" | decode | grep -qi "$TEST_DOMAIN" && { site_ok=1; break; }
    sleep 10
  done
  [ "$site_ok" = 1 ] && ok "hosted site back after $1" || fail "hosted site did not recover after $1"
  for _ in $(seq 1 12); do
    site_php | grep -q "PHP_OK:7" && { php_ok=1; break; }
    sleep 5
  done
  [ "$php_ok" = 1 ] && ok "PHP (domain pool) back after $1" || fail "PHP did not recover after $1"
}

if [ -n "$RESTART_CMD" ]; then
  echo "== 16. restart recovery"
  # A container recreation can come back with the SAME IP (persisted Hestia
  # IP record present, /etc configs gone - historically 502s) or a NEW IP
  # (stale record repoint path). Both must recover. If the first restart
  # lands on a new IP, restart once more - the freed IP is usually reused,
  # exercising the same-IP path too.
  ip_before="$(get_sys_ip)"
  echo "  restarting via: $RESTART_CMD (container IP before: ${ip_before:-unknown})"
  if eval "$RESTART_CMD" >/dev/null 2>&1; then
    verify_recovery "restart"
    login
    ip_after="$(get_sys_ip)"
    if [ -n "$ip_before" ] && [ "$ip_before" = "$ip_after" ]; then
      ok "same-IP recreate path exercised (IP stayed $ip_after)"
    else
      echo "  (first restart changed IP: ${ip_before:-?} -> ${ip_after:-?}; restarting again to exercise the same-IP path)"
      if eval "$RESTART_CMD" >/dev/null 2>&1; then
        verify_recovery "second restart"
        login
        ip_after2="$(get_sys_ip)"
        if [ -n "$ip_after" ] && [ "$ip_after" = "$ip_after2" ]; then
          ok "same-IP recreate path exercised (IP stayed $ip_after2)"
        else
          skip "could not pin the same-IP path (IPs: ${ip_before:-?} -> ${ip_after:-?} -> ${ip_after2:-?})"
        fi
      else
        fail "second restart command failed"
      fi
    fi
  else
    fail "restart command failed"
  fi
else
  echo "== 16. restart recovery: SKIPPED (set RESTART_CMD to enable)"
fi

if [ -n "$UPDATE_CMD" ]; then
  echo "== 17. update simulation"
  echo "  updating via: $UPDATE_CMD"
  if eval "$UPDATE_CMD" >/dev/null 2>&1; then
    verify_recovery "update"
  else
    fail "update command failed"
  fi
else
  echo "== 17. update simulation: SKIPPED (set UPDATE_CMD to enable)"
fi

if [ -n "$STATS_CMD" ]; then
  echo "== 18. resource snapshot (informational)"
  eval "$STATS_CMD" 2>&1 | head -10 | sed 's/^/  /'
fi

echo
echo "RESULT: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" = 0 ]
