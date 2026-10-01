#!/bin/sh
# Git pre-push hook: a push to master builds and pushes the image on this Mac instead of in
# GitHub Actions. Install once: ln -s ../../infra/push-image.sh .git/hooks/pre-push
# Builds the pushed commit from `git archive`, never the working tree. A failed build stops the
# push; `git push --no-verify` skips the build.
set -eu
image=ghcr.io/roandegraaf/desklings
zero=0000000000000000000000000000000000000000

while read -r _ sha ref _; do
  [ "$ref" = refs/heads/master ] && [ "$sha" != "$zero" ] || continue
  git archive "$sha" | docker buildx build --platform linux/amd64 --push \
    -t "$image:latest" -t "$image:$sha" -
done
