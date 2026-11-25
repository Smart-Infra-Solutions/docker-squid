#!/bin/sh
#
# Copies the image tested for this commit (sha-<commit> on GHCR) to its public
# tags on GHCR and Docker Hub. Run by .woodpecker/publish.yaml with regctl.

set -eu

SOURCE_REPO=ghcr.io/smart-infra-solutions/docker-squid
TARGET_REPOS="ghcr.io/smart-infra-solutions/docker-squid docker.io/smartinfrasolutions/squid"

if [ -n "${CI_COMMIT_TAG:-}" ]; then
    TAG="$CI_COMMIT_TAG"
else
    TAG=latest
fi

echo "$GHCR_TOKEN" | regctl registry login ghcr.io -u "$GHCR_USERNAME" --pass-stdin
echo "$DOCKERHUB_TOKEN" | regctl registry login docker.io -u "$DOCKERHUB_USERNAME" --pass-stdin

for repo in $TARGET_REPOS; do
    echo "Publishing $SOURCE_REPO:sha-$CI_COMMIT_SHA as $repo:$TAG"
    regctl image copy "$SOURCE_REPO:sha-$CI_COMMIT_SHA" "$repo:$TAG"
done
