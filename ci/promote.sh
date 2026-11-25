#!/bin/sh
#
# Copies the image tested for this commit (sha-<commit> on GHCR) to its public
# tag on one target registry. Run by .woodpecker/publish.yaml with regctl,
# once per registry so a failure on one does not block the other.
#
# Environment: TARGET_REPO (e.g. ghcr.io/org/image), REGISTRY_USERNAME,
# REGISTRY_TOKEN. The source image is public, so it is read anonymously.

set -eu

SOURCE_REPO=ghcr.io/smart-infra-solutions/docker-squid
TARGET_REGISTRY="${TARGET_REPO%%/*}"

if [ -n "${CI_COMMIT_TAG:-}" ]; then
    TAG="$CI_COMMIT_TAG"
else
    TAG=latest
fi

[ -n "${REGISTRY_TOKEN:-}" ] || { echo "No token for $TARGET_REGISTRY (check the Woodpecker secret)" >&2; exit 1; }
echo "$REGISTRY_TOKEN" | regctl registry login "$TARGET_REGISTRY" -u "$REGISTRY_USERNAME" --pass-stdin

echo "Publishing $SOURCE_REPO:sha-$CI_COMMIT_SHA as $TARGET_REPO:$TAG"
regctl image copy "$SOURCE_REPO:sha-$CI_COMMIT_SHA" "$TARGET_REPO:$TAG"
