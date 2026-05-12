# tools/sparkle

`scripts/publish_release.sh` needs Sparkle's `sign_update` to EdDSA-sign each
release `.zip`. Sparkle distributes the CLI tools as part of its release
tarball, NOT inside the `brew install --cask sparkle` Test App. The binary
is ~1.3 MB, MIT-licensed, but kept out of git (binaries don't belong in
version control).

If you've just cloned this repo and `./scripts/publish_release.sh` complains
about a missing `sign_update`, drop one in here:

```bash
SPARKLE_VERSION=2.9.1   # any 2.x; CFBundleShortVersionString match isn't required
curl -fsSL -o /tmp/sparkle.tar.xz \
  "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
mkdir -p /tmp/sparkle && tar -xf /tmp/sparkle.tar.xz -C /tmp/sparkle

# Place into this directory (gitignored).
cp /tmp/sparkle/bin/sign_update tools/sparkle/sign_update
chmod +x tools/sparkle/sign_update

# Cleanup.
rm -rf /tmp/sparkle /tmp/sparkle.tar.xz
```

`publish_release.sh` looks at this folder first, so once `sign_update` is in
place no further configuration is needed.

The EdDSA **private key** lives in your macOS Keychain (placed by
`generate_keys` once at project bootstrap) plus a backup in your password
manager. It does NOT live in this folder. If you lose it, future releases
will be rejected by every installed copy — there is no recovery short of
publishing a new public key and asking users to reinstall.
