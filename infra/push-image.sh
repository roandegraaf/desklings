#!/bin/sh
# Git pre-push hook: a push to master builds and pushes the image on this Mac instead of in
# GitHub Actions. Install once: ln -s ../../infra/push-image.sh .git/hooks/pre-push
# Builds the pushed commit from `git archive`, never the working tree, in the background so the
# push is not held up. Output goes to $TMPDIR/desklings-image.log; the result is a notification.
set -eu
image=ghcr.io/roandegraaf/desklings
log="${TMPDIR:-/tmp}/desklings-image.log"
zero=0000000000000000000000000000000000000000

while read -r _ sha ref _; do
  [ "$ref" = refs/heads/master ] && [ "$sha" != "$zero" ] || continue
  echo "building $image:$sha in the background, log: $log" >&2
  # ponytail: two pushes in quick succession build in parallel and the slower one wins :latest.
  (
    if git archive "$sha" | docker buildx build --platform linux/amd64 --push \
      -t "$image:latest" -t "$image:$sha" -; then
      msg="Pushed $image:latest"
    else
      msg="Image build failed, see $log"
    fi
    osascript -e "display notification \"$msg\" with title \"desklings\""
  ) >"$log" 2>&1 &
done
