#!/usr/bin/env bash
#
# Proves a built repository is one apt will actually accept.
#
#   ./test_install.sh <deb> [<deb>...]
#
# Builds the repository with a throwaway key, serves it on localhost, and then
# follows the published instructions inside a clean Debian container: install
# the keyring, install the .sources file, `apt-get update`, resolve and download
# every package. A wrong hash, a bad signature, a keyring in the wrong format or
# a path that does not match the index all fail here rather than on someone's
# machine.
#
# Needs docker, gpg, apt-utils and python3. Runs as it stands on a GitHub
# ubuntu runner.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT=8765
WORK="$(mktemp -d)"
trap 'kill "${SERVER_PID:-}" 2>/dev/null || true; rm -rf "$WORK"' EXIT

GNUPGHOME="$WORK/gnupg"
mkdir -m 700 "$GNUPGHOME"
export GNUPGHOME
gpg --batch --quiet --passphrase '' \
  --quick-generate-key 'Throwaway test key <test@invalid>' ed25519 sign 1d
APT_GPG_PRIVATE_KEY="$(gpg --batch --armor --export-secret-keys)"
export APT_GPG_PRIVATE_KEY
unset GNUPGHOME

BASE_URL="http://localhost:$PORT" bash "$HERE/build_repo.sh" "$WORK/repo" "$@"

python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$WORK/repo" \
  > /dev/null 2>&1 &
SERVER_PID=$!
sleep 1

PACKAGES="$(for deb in "$@"; do dpkg-deb -f "$deb" Package; done | sort -u | xargs)"

# The commands below are the ones index.html tells people to run, minus sudo.
docker run --rm --network host debian:12-slim bash -euxc "
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends curl ca-certificates > /dev/null
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL http://localhost:$PORT/buache-systems-archive-keyring.gpg \
    > /etc/apt/keyrings/buache-systems.gpg
  curl -fsSL -o /etc/apt/sources.list.d/buache-systems.sources \
    http://localhost:$PORT/buache-systems.sources
  # Debug output, so the log shows which URL the index was fetched from. It
  # has to be the by-hash one: that is what keeps a CDN serving two
  # generations at once from breaking apt update.
  apt-get update -o Debug::Acquire::http=true 2>&1 | tee /tmp/update.log
  grep -q "by-hash/SHA" /tmp/update.log
  apt-cache policy $PACKAGES
  # -s resolves the dependencies against Debian without installing a desktop.
  apt-get install -s $PACKAGES
  # download checks the .deb against the signed index.
  cd /tmp && apt-get download $PACKAGES && ls -l *.deb
"

echo "apt accepted the repository and every package in it: $PACKAGES"
