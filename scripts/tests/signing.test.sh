#!/bin/bash
# Offline signing/installation fixture tests; never touch /Applications or TCC.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
work=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/voiceinput-signing-test.XXXXXX")
trap '/bin/rm -rf "$work"' EXIT

fixture() {
    local app=$1 version=$2
    /bin/mkdir -p "$app/Contents/MacOS"
    /usr/bin/clang -x c -Os -o "$app/Contents/VoiceInputSigningFixture" - <<C
#include <unistd.h>
int main(void) { sleep(2); return $version; }
C
    /bin/mv "$app/Contents/VoiceInputSigningFixture" "$app/Contents/MacOS/VoiceInputSigningFixture"
    /bin/cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.zhijie.VoiceInput</string>
<key>CFBundleExecutable</key><string>VoiceInputSigningFixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>$version</string>
</dict></plist>
PLIST
}
requirement() { /usr/bin/codesign -d -r- "$1" 2>&1 | /usr/bin/sed -n 's/^designated => //p'; }
cdhash() { /usr/bin/codesign -dv --verbose=4 "$1" 2>&1 | /usr/bin/sed -n 's/^CDHash=//p'; }
install_fixture() { INSTALL_DIR="$work/install" BACKUP_DIR="$work/backups" bash "$repo/scripts/install-app.sh" "$1"; }

fixture "$work/v1.app" 1
fixture "$work/v2.app" 2
bash "$repo/scripts/sign-app.sh" "$work/v1.app"
bash "$repo/scripts/sign-app.sh" "$work/v2.app"
[[ "$(cdhash "$work/v1.app")" != "$(cdhash "$work/v2.app")" ]]
requirement "$work/v1.app" > "$work/v1.req"
requirement "$work/v2.app" > "$work/v2.req"
/usr/bin/codesign --verify --strict -R "$work/v1.req" "$work/v2.app"
/usr/bin/codesign --verify --strict -R "$work/v2.req" "$work/v1.app"
printf '%s\n' 'PASS: differing binaries signed by the same identity satisfy each other’s designated requirements.'

/bin/mkdir -p "$work/install"
fixture "$work/install/VoiceInput.app" 0
SIGNING_IDENTITY=- ALLOW_ADHOC=1 bash "$repo/scripts/sign-app.sh" "$work/install/VoiceInput.app"
if SIGNING_IDENTITY=- ALLOW_ADHOC=0 bash "$repo/scripts/sign-app.sh" "$work/install/VoiceInput.app" >/dev/null 2>&1; then
    printf '%s\n' 'FAIL: ad-hoc signing did not require explicit opt-in.' >&2; exit 1
fi
if install_fixture "$work/install/VoiceInput.app" >/dev/null 2>&1; then
    printf '%s\n' 'FAIL: installer accepted an ad-hoc release.' >&2; exit 1
fi
printf '%s\n' 'PASS: ad-hoc signing requires explicit opt-in and installation rejects ad-hoc releases.'

install_fixture "$work/v1.app"
[[ "$(cdhash "$work/install/VoiceInput.app")" == "$(cdhash "$work/v1.app")" ]]
install_fixture "$work/v2.app"
[[ "$(cdhash "$work/install/VoiceInput.app")" == "$(cdhash "$work/v2.app")" ]]
backup_count=$(/usr/bin/find "$work/backups" -name designated-requirement.txt | /usr/bin/wc -l | /usr/bin/tr -d ' ')
[[ "$backup_count" == 2 ]]
printf '%s\n' 'PASS: temporary-directory ad-hoc migration, stable update and both backups verified.'

# A still-valid signature can have an incompatible DR even with the same
# certificate and bundle ID. Restrict this fixture to its version to prove
# the installer checks mutual requirements rather than merely matching names.
/usr/bin/ditto "$work/v1.app" "$work/incompatible.app"
/usr/bin/codesign -d --extract-certificates="$work/leaf" "$work/v1.app" 2>/dev/null
identity=$(/usr/bin/shasum -a 1 "$work/leaf0" | /usr/bin/awk '{ print $1 }')
printf 'designated => (%s) and info[CFBundleVersion] = "1"\n' "$(cat "$work/v1.req")" > "$work/incompatible.req"
/usr/bin/codesign --force --sign "$identity" --timestamp=none --requirements "$work/incompatible.req" "$work/incompatible.app"
/usr/bin/codesign --verify --strict "$work/incompatible.app"
if install_fixture "$work/incompatible.app" >/dev/null 2>&1; then
    printf '%s\n' 'FAIL: installer accepted an incompatible designated requirement.' >&2; exit 1
fi
[[ "$(cdhash "$work/install/VoiceInput.app")" == "$(cdhash "$work/v2.app")" ]]
printf '%s\n' 'PASS: incompatible designated requirement is rejected even when the certificate matches.'

/usr/bin/ditto "$work/v1.app" "$work/tampered.app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 999' "$work/tampered.app/Contents/Info.plist"
if install_fixture "$work/tampered.app" >/dev/null 2>&1; then
    printf '%s\n' 'FAIL: installer accepted a tampered signature.' >&2; exit 1
fi
[[ "$(cdhash "$work/install/VoiceInput.app")" == "$(cdhash "$work/v2.app")" ]]
printf '%s\n' 'PASS: invalid update leaves the installed fixture untouched.'

# Only launch our short-lived, no-I/O fixture, never the user's VoiceInput.
"$work/install/VoiceInput.app/Contents/MacOS/VoiceInputSigningFixture" &
fixture_pid=$!
if install_fixture "$work/v1.app" >/dev/null 2>&1; then
    printf '%s\n' 'FAIL: running-app replacement did not require explicit opt-in.' >&2; exit 1
fi
ALLOW_RUNNING_UPDATE=1 install_fixture "$work/v1.app"
kill -0 "$fixture_pid"
wait "$fixture_pid" || true
printf '%s\n' 'PASS: running update needs explicit opt-in and leaves the existing process alive.'
