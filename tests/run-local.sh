#!/bin/sh
#
# Builds the image and runs tests/smoke.sh against it, the same way the
# Woodpecker "test" workflow does. Needs Docker. Usage: tests/run-local.sh
# (set IMAGE to test an already-built/published image instead of building).

set -eu

cd "$(dirname "$0")/.."

IMAGE="${IMAGE:-docker-squid:test}"
NAME="docker-squid-smoke-$$"

if [ "$IMAGE" = "docker-squid:test" ]; then
    docker build -t "$IMAGE" .
fi

cleanup() {
    docker rm -f "$NAME-squid" >/dev/null 2>&1 || true
    docker network rm "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker network create "$NAME" >/dev/null
docker run -d --name "$NAME-squid" --network "$NAME" --network-alias squid "$IMAGE" >/dev/null

if ! docker run --rm --network "$NAME" -v "$PWD/tests:/tests:ro" alpine:3.24 \
        sh -c 'apk add --no-cache -q curl busybox-extras && sh /tests/smoke.sh'; then
    echo "--- squid container logs (last 100 lines) ---" >&2
    docker logs --tail 100 "$NAME-squid" >&2
    exit 1
fi
