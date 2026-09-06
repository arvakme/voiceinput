# Keep permissions across local updates

`make build` signs VoiceInput with a certificate instead of an ad-hoc signature.
The bundle identifier stays `com.zhijie.VoiceInput`, and `make install` keeps the
application at `/Applications/VoiceInput.app`.

macOS records the app's designated code requirement when granting privacy access.
An ad-hoc requirement is tied to a particular build, so rebuilding changes the
identity macOS checks. Certificate-signed updates can satisfy the same requirement.
See [Apple TN3127: Inside Code Signing: Requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).

## Choose a persistent signing identity

List existing application-signing certificates:

```sh
security find-identity -v -p codesigning
```

Pin one certificate's SHA-1 in `.signing.local.mk`:

```make
SIGNING_IDENTITY := YOUR_CERTIFICATE_SHA1
```

This file is gitignored. Do not commit personal certificate pins or private keys.
You can also pass `SIGNING_IDENTITY=...` to `make` directly. With no pin, the build
uses a certificate only when exactly one valid Apple Development, Mac Developer,
or Developer ID Application identity is available. Ambiguous or missing identities
fail with instructions instead of silently using ad-hoc signing.

```sh
make build
make install
```

The existing SDK workaround in README still applies when needed; for example:

```sh
make install SWIFT_FLAGS='--sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk'
```

The local build does not add hardened runtime, sandbox entitlements or a custom
weakened designated requirement. Certificate signing for this local workflow
is separate from notarization/distribution requirements.

## Installation behavior

Before replacing an app, the installer:

1. Verifies the new signature and bundle/signing identifiers.
2. Checks that old and new designated requirements are mutually compatible.
3. Backs up the installed app and its requirement under
   `~/Library/Application Support/VoiceInput/Install Backups/`.
4. Stages and verifies the replacement, rolling back if the final replacement fails.

An old ad-hoc installation is allowed to migrate to certificate signing once.
That changes identity, so expect a one-time permission grant after this update.
Future compatible updates retain the certificate identity. The installer does
not reset permissions, edit TCC databases or remove app preferences.

By default, installation asks you to finish dictation and quit the running app
normally. To replace the on-disk app while leaving the current process running:

```sh
make install ALLOW_RUNNING_UPDATE=1
```

This sends no quit or kill signal. The new version runs after your next normal
quit and restart. The previous signed app remains in the backup directory.

If a later update fails the requirement check, keep the original certificate pin
and rebuild. Do not bypass the check by switching back to an ad-hoc signature.

## Disposable builds and tests

```sh
make dev-build     # explicit ad-hoc opt-in, for local experimentation only
make test-signing  # existing certificate required; fixtures remain in temp dirs
```

The installer rejects ad-hoc builds. `test-signing` compiles two different tiny
programs and verifies their requirements in both directions. It also checks
one-time ad-hoc migration, backups, tamper/incompatible-requirement rejection,
and that an explicitly allowed update leaves a running fixture process alive.
It never replaces `/Applications/VoiceInput.app` or requests privacy access.
