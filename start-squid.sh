#!/command/with-contenv sh

set -e

CHOWN=$(/usr/bin/which chown)
SQUID=$(/usr/bin/which squid)

# Ensure permissions are set correctly on the Squid cache + log dir.
"$CHOWN" -R squid:squid /var/cache/squid
"$CHOWN" -R squid:squid /var/log/squid

# With bypass=off (the default), Squid's first ICAP OPTIONS probe marks the
# antivirus service permanently down for this run if c-icap isn't reachable
# yet, since it isn't retried right away. Wait for it before starting Squid.
if [ "${ENABLE_ANTIVIRUS:-true}" = "true" ]; then
    echo "Waiting for c-icap to be ready..."
    i=0
    until nc -z 127.0.0.1 1344 2>/dev/null; do
        i=$((i + 1))
        if [ "$i" -ge 60 ]; then
            echo "c-icap did not become ready in time, starting Squid anyway."
            break
        fi
        sleep 1
    done
fi

# Prepare the cache using Squid.
echo "Initializing cache..."
"$SQUID" -z

# Give the Squid cache some time to rebuild.
sleep 5

# Launch squid
echo "Starting Squid..."
exec "$SQUID" -NYCd 1
