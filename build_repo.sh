#!/usr/bin/env bash
#
# Builds the signed APT repository for every Buache Systems application.
#
#   ./build_repo.sh <output-dir> <deb> [<deb>...]
#
# The repository is rebuilt from nothing on every run. The packages themselves
# live on each application's GitHub Releases page; this script only arranges the
# ones it is handed into a pool, indexes them and signs the index. Nothing here
# is state, so there is no history of binaries to carry around in git.
#
# Signing needs a private key in the environment:
#   APT_GPG_PRIVATE_KEY   ASCII-armoured private key
#   APT_GPG_PASSPHRASE    its passphrase (optional if the key has none)
#
# Without a key the repository is still generated but left unsigned, which is
# enough to look at the layout; apt itself will refuse an unsigned repository.
#
#   BASE_URL              where the output will be served from. It ends up in
#                         the .sources file users install, so it is the one
#                         value here that is expensive to change later.

set -euo pipefail

OUTPUT="${1:?usage: build_repo.sh <output-dir> <deb>...}"
shift
if [[ $# -eq 0 ]]; then
  echo "no .deb files given" >&2
  exit 2
fi

ORIGIN="Buache Systems"
LABEL="Buache Systems"
SUITE="stable"
COMPONENT="main"
BASE_URL="${BASE_URL:-https://alpinsuite.github.io/apt}"
NAME="buache-systems"
KEYRING_NAME="$NAME-archive-keyring.gpg"

mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"

# pool/main/p/paint/paint_0.2.0_amd64.deb, the layout Debian itself uses. The
# package name and architecture are read from the control file rather than
# guessed from the file name, which nothing obliges to be truthful.
ARCHITECTURES=""
for deb in "$@"; do
  package="$(dpkg-deb -f "$deb" Package)"
  arch="$(dpkg-deb -f "$deb" Architecture)"
  dir="$OUTPUT/pool/$COMPONENT/${package:0:1}/$package"
  mkdir -p "$dir"
  cp -f "$deb" "$dir/"
  if [[ "$arch" != "all" && " $ARCHITECTURES " != *" $arch "* ]]; then
    ARCHITECTURES="${ARCHITECTURES:+$ARCHITECTURES }$arch"
  fi
done
ARCHITECTURES="${ARCHITECTURES:-amd64}"

cd "$OUTPUT"

# apt-ftparchive walks pool/ and writes the package index. Paths in the index
# must be relative to the repository root, hence running from here.
for arch in $ARCHITECTURES; do
  mkdir -p "dists/$SUITE/$COMPONENT/binary-$arch"
  apt-ftparchive --arch "$arch" packages pool \
    > "dists/$SUITE/$COMPONENT/binary-$arch/Packages"
  gzip -9nkf "dists/$SUITE/$COMPONENT/binary-$arch/Packages"
done

CONF="$(mktemp)"
cat > "$CONF" <<CONF
APT::FTPArchive::Release::Origin "$ORIGIN";
APT::FTPArchive::Release::Label "$LABEL";
APT::FTPArchive::Release::Suite "$SUITE";
APT::FTPArchive::Release::Codename "$SUITE";
APT::FTPArchive::Release::Architectures "$ARCHITECTURES";
APT::FTPArchive::Release::Components "$COMPONENT";
APT::FTPArchive::Release::Description "Buache Systems desktop applications";
CONF

# Written outside the tree first: the shell would otherwise create an empty
# Release before apt-ftparchive scans the directory, and it would hash that
# placeholder into its own index.
RELEASE_TMP="$(mktemp)"
apt-ftparchive -c "$CONF" release "dists/$SUITE" > "$RELEASE_TMP"
rm -f "$CONF"

# Acquire-By-Hash, because this is served from a CDN. For ten minutes after a
# publish an edge may hold the new InRelease and the old Packages, or the other
# way round, and apt rightly refuses an index whose hash is not the signed one:
# "Hash Sum mismatch", for every user who updates in that window. With this
# field apt asks for the index by its hash instead of by its name, so whichever
# InRelease a client was given, the Packages it names is a different URL from
# the other generation's and cannot be confused with it.
#
# The field goes in the header, before the hash lists; the by-hash copies are
# made after Release is written so that apt-ftparchive does not index them.
sed -i '0,/^MD5Sum:/s//Acquire-By-Hash: yes\nMD5Sum:/' "$RELEASE_TMP"
grep -q '^Acquire-By-Hash: yes$' "$RELEASE_TMP"
mv "$RELEASE_TMP" "dists/$SUITE/Release"

by_hash() {
  local file="$1" dir
  dir="$(dirname "$file")/by-hash/SHA256"
  mkdir -p "$dir"
  cp -f "$file" "$dir/$(sha256sum "$file" | cut -d' ' -f1)"
}
for arch in $ARCHITECTURES; do
  by_hash "dists/$SUITE/$COMPONENT/binary-$arch/Packages"
  by_hash "dists/$SUITE/$COMPONENT/binary-$arch/Packages.gz"
done

# The generation being replaced stays reachable by hash too. The tree is
# rebuilt from nothing each time, so without this the index a stale InRelease
# names would have just been deleted — which is the case this exists for.
# PREVIOUS_URL is the live repository; absent on a first publish and in tests.
if [[ -n "${PREVIOUS_URL:-}" ]]; then
  for arch in $ARCHITECTURES; do
    for name in Packages Packages.gz; do
      previous="$(mktemp)"
      if curl -fsSL -o "$previous" \
           "$PREVIOUS_URL/dists/$SUITE/$COMPONENT/binary-$arch/$name"; then
        dir="dists/$SUITE/$COMPONENT/binary-$arch/by-hash/SHA256"
        cp -f "$previous" "$dir/$(sha256sum "$previous" | cut -d' ' -f1)"
      fi
      rm -f "$previous"
    done
  done
fi

if [[ -n "${APT_GPG_PRIVATE_KEY:-}" ]]; then
  GNUPGHOME="$(mktemp -d)"
  export GNUPGHOME
  chmod 700 "$GNUPGHOME"
  printf '%s' "$APT_GPG_PRIVATE_KEY" | gpg --batch --quiet --import

  KEY_ID="$(gpg --list-secret-keys --with-colons | awk -F: '/^sec:/ {print $5; exit}')"
  if [[ -z "$KEY_ID" ]]; then
    echo "the supplied APT_GPG_PRIVATE_KEY contains no secret key" >&2
    exit 1
  fi

  GPG_ARGS=(--batch --yes --quiet --local-user "$KEY_ID")
  if [[ -n "${APT_GPG_PASSPHRASE:-}" ]]; then
    GPG_ARGS+=(--pinentry-mode loopback --passphrase "$APT_GPG_PASSPHRASE")
  fi

  # Both signatures are produced: InRelease for modern apt, Release.gpg for
  # older clients that still look for a detached signature.
  gpg "${GPG_ARGS[@]}" --clearsign \
    --output "dists/$SUITE/InRelease" "dists/$SUITE/Release"
  gpg "${GPG_ARGS[@]}" --armor --detach-sign \
    --output "dists/$SUITE/Release.gpg" "dists/$SUITE/Release"

  # The public key is published in binary (dearmoured) form, which is what
  # Signed-By expects in /etc/apt/keyrings.
  gpg --batch --yes --export "$KEY_ID" > "$KEYRING_NAME"

  rm -rf "$GNUPGHOME"
  unset GNUPGHOME
  echo "signed with $KEY_ID"
else
  echo "warning: APT_GPG_PRIVATE_KEY is not set; repository left unsigned" >&2
fi

# A ready-made deb822 source file, so installing is two commands rather than a
# hand-written sources.list line.
cat > "$NAME.sources" <<SOURCES
Types: deb
URIs: $BASE_URL
Suites: $SUITE
Components: $COMPONENT
Architectures: $ARCHITECTURES
Signed-By: /etc/apt/keyrings/$NAME.gpg
SOURCES

# Someone will open the bare URL in a browser. This says what it is and sends
# them to the site; the site is where the explaining happens.
PACKAGE_ROWS="$(find pool -name '*.deb' | sort -V | while read -r path; do
  echo "  <li><a href=\"$path\">$(basename "$path")</a></li>"
done)"
cat > index.html <<HTML
<!doctype html>
<html lang="en">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>Buache Systems APT repository</title>
<style>
  body { font: 1rem/1.6 system-ui, sans-serif; max-width: 44rem;
         margin: 3rem auto; padding: 0 1rem; }
  pre { overflow-x: auto; padding: 1rem; border: 1px solid #8884;
        border-radius: 6px; font-size: .875rem; }
</style>
<h1>Buache Systems APT repository</h1>
<p>This address is for <code>apt</code>, not for people. The applications, and
   what they do, are at <a href="https://buache.systems/">buache.systems</a>.</p>
<pre><code>sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL $BASE_URL/$KEYRING_NAME \\
  | sudo tee /etc/apt/keyrings/$NAME.gpg > /dev/null
sudo curl -fsSL -o /etc/apt/sources.list.d/$NAME.sources \\
  $BASE_URL/$NAME.sources
sudo apt update</code></pre>
<h2>Packages</h2>
<ul>
$PACKAGE_ROWS
</ul>
HTML

# GitHub Pages runs Jekyll by default; this disables it, so the tree is served
# exactly as it was built.
touch .nojekyll

echo "APT repository written to $OUTPUT"
find dists pool -type f | sort | sed 's/^/  /'
