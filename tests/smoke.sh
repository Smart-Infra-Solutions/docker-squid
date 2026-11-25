#!/bin/sh
#
# End-to-end smoke test of a running docker-squid container.
#
# Serves two files from a throwaway HTTP server started here (a harmless text
# file and the EICAR antivirus test file), then fetches them through the
# proxy: the first must come through intact, the second must be blocked by
# the ClamAV/c-icap scanning. Also checks Squid's CONNECT access rules.
#
# Needs curl and busybox-extras (httpd), e.g. on Alpine:
#   apk add --no-cache curl busybox-extras
#
# Environment:
#   PROXY         proxy URL under test        (default: http://squid:3128)
#   READY_TIMEOUT seconds to wait for it      (default: 900; the first start
#                 downloads the ~200-300 MB ClamAV signature database)

set -eu

PROXY="${PROXY:-http://squid:3128}"
READY_TIMEOUT="${READY_TIMEOUT:-900}"
PORT=8080

WWW=$(mktemp -d)
trap 'rm -rf "$WWW"; kill "$HTTPD_PID" 2>/dev/null || true' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

# --- Fixtures --------------------------------------------------------------

echo "docker-squid smoke test: clean file" > "$WWW/clean.txt"

# The EICAR test file, assembled at runtime (\044 is "$") so this script is
# not itself flagged by the antivirus of whoever checks it out.
EICAR_TAIL='EICAR-STANDARD-ANTIVIRUS-TEST-FILE!'
printf 'X5O!P%%@AP[4\PZX54(P^)7CC)7}\044%s\044H+H*' "$EICAR_TAIL" > "$WWW/eicar.com"

busybox-extras httpd -f -p "$PORT" -h "$WWW" &
HTTPD_PID=$!

# Reached by IP so Squid does not need to resolve this container's name.
MY_IP=$(hostname -i | awk '{print $1}')
ORIGIN="http://$MY_IP:$PORT"
echo "Test origin: $ORIGIN, proxy: $PROXY"

# --- Wait for the proxy ----------------------------------------------------
# Squid only starts listening once c-icap is up, and ICAP runs fail-closed
# (ICAP_BYPASS=off): a successful fetch means the whole chain is ready.

echo "Waiting up to ${READY_TIMEOUT}s for the proxy..."
start=$(date +%s)
until curl -fsS -o /dev/null --max-time 10 -x "$PROXY" "$ORIGIN/clean.txt" 2>/dev/null; do
    elapsed=$(( $(date +%s) - start ))
    [ "$elapsed" -lt "$READY_TIMEOUT" ] || fail "proxy not ready after ${READY_TIMEOUT}s"
    sleep 5
done
echo "Proxy ready after $(( $(date +%s) - start ))s."

# --- Tests -----------------------------------------------------------------

echo "1. A clean file is delivered unchanged"
body=$(curl -fsS --max-time 30 -x "$PROXY" "$ORIGIN/clean.txt")
[ "$body" = "docker-squid smoke test: clean file" ] || fail "unexpected body: $body"

echo "2. The EICAR test file is blocked"
code=$(curl -sS -o "$WWW/eicar.out" -w '%{http_code}' --max-time 60 -x "$PROXY" "$ORIGIN/eicar.com")
if grep -q "$EICAR_TAIL" "$WWW/eicar.out"; then
    fail "EICAR test file was delivered (HTTP $code): antivirus scanning is not working"
fi
[ "$code" = "403" ] || fail "expected HTTP 403 for EICAR, got $code"

echo "3. CONNECT to a non-SSL port is denied"
code=$(curl -s -o /dev/null -w '%{http_connect}' --max-time 30 -p -x "$PROXY" "$ORIGIN/clean.txt" || true)
[ "$code" = "403" ] || fail "expected CONNECT to port $PORT to be denied (403), got $code"

echo "All smoke tests passed."
