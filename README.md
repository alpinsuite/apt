# apt

The signed APT repository for every Buache Systems application: one key, one
`.sources` file, and `apt upgrade` keeps all of them current.

```bash
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://alpinsuite.github.io/apt/buache-systems-archive-keyring.gpg \
  | sudo tee /etc/apt/keyrings/buache-systems.gpg > /dev/null
sudo curl -fsSL -o /etc/apt/sources.list.d/buache-systems.sources \
  https://alpinsuite.github.io/apt/buache-systems.sources
sudo apt update
```

## How it works

There are no packages in this repository and no server behind it. The `.deb`
files live on each application's GitHub Releases page. Once an hour, and on
every push here, `.github/workflows/publish.yml`:

1. reads `apps.txt` and downloads the `.deb`s from the newest three published
   releases of each repository listed (`collect_debs.sh`);
2. builds the repository with a throwaway key and has a clean Debian container
   follow the install instructions against it (`test_install.sh`);
3. builds it again with the real key (`build_repo.sh`) and deploys the result to
   GitHub Pages.

The whole tree is rebuilt from nothing each time, so the Releases pages are the
only source of truth. Deleting a release removes it from apt at the next run.
The hourly run compares `manifest.txt` with the live one and deploys only when
a release appeared, changed or went away.

It pulls rather than being pushed to. An application's release workflow does not
know this repository exists, holds no signing key and needs no token. To publish
a fresh release without waiting for the hour:

```bash
gh workflow run publish.yml -R alpinsuite/apt
```

## Adding an application

Add `owner/repo` to `apps.txt`. The repository must be public and have a
published (not draft, not pre-release) release with a `.deb` attached. That is
all; the package name and architecture are read from the `.deb` itself.

## The key

`APT_GPG_PRIVATE_KEY` (ASCII-armoured) and `APT_GPG_PASSPHRASE` are secrets of
this repository. Until they are set the workflow tests the build and deploys
nothing, because apt refuses an unsigned repository. An application needs them
only if it also signs the `SHA256SUMS` of its releases, as Paint does; nothing
about publishing to apt requires it.

Every installed machine trusts this key by file, in `/etc/apt/keyrings`. If it
is lost, every user has to fetch a new keyring by hand, so:

- keep a copy of the private key and a revocation certificate somewhere that is
  not GitHub;
- prefer giving CI a signing subkey with an expiry, and keeping the primary key
  offline. A new subkey is picked up by re-downloading the same keyring URL; a
  new primary key is not.

## The address

`BASE_URL` is written into the `.sources` file that users install, so it is the
one thing here that is expensive to change: every machine that already
installed the old file keeps asking the old address.

It defaults to `https://alpinsuite.github.io/apt`. Before the first public
announcement, move it to a name the project owns:

1. DNS: `apt.buache.systems` `CNAME` `alpinsuite.github.io.`
2. Settings → Pages → Custom domain → `apt.buache.systems`, then Enforce HTTPS.
3. Settings → Variables → Actions → `APT_BASE_URL` = `https://apt.buache.systems`
4. Run the workflow, and change the URLs at the top of this file.

After that the hosting can move anywhere that serves static files without
anyone's machine noticing.

## Running it locally

On Debian or Ubuntu, or in WSL, with `apt-utils`, `gpg`, `gh` and docker:

```bash
bash collect_debs.sh debs > manifest.txt
bash test_install.sh debs/*.deb
```

## Licence

GPL-3.0-or-later. The build script began as Paint's `packaging/publish_apt.sh`.
