#!/usr/bin/env bash
#
# Downloads the packages the repository should contain.
#
#   ./collect_debs.sh <download-dir> > manifest.txt
#
# For every repository in apps.txt, takes the newest $KEEP published releases
# that carry a .deb and downloads those .debs. Drafts and pre-releases are
# skipped: `apt upgrade` would hand a pre-release to everyone.
#
# The manifest on stdout names every asset by id and upload time, so two runs
# that would publish the same bytes print the same text. The workflow compares
# it with the one already live and skips the deploy when nothing moved.
#
# Needs `gh`, and GH_TOKEN in the environment when run in CI.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${1:?usage: collect_debs.sh <download-dir>}"
KEEP="${KEEP:-3}"

mkdir -p "$DEST"

grep -vE '^\s*(#|$)' "$HERE/apps.txt" | while read -r repo; do
  gh api "repos/$repo/releases?per_page=30" --jq "
    [ .[]
      | select(.draft | not)
      | select(.prerelease | not)
      | select(any(.assets[]; .name | endswith(\".deb\"))) ][:$KEEP][]
    | .tag_name as \$tag
    | .assets[]
    | select(.name | endswith(\".deb\"))
    | \"\(\$tag) \(.name) \(.id) \(.updated_at)\"" \
  | while read -r tag name id updated; do
      gh release download "$tag" -R "$repo" -p "$name" -D "$DEST" --clobber
      echo "$repo $tag $name $id $updated"
    done
done
