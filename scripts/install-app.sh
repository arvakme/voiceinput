#!/bin/bash
# Validate identity continuity and replace an inactive app, retaining a backup.
set -euo pipefail

source_app=${1:-VoiceInput.app}
install_dir=${INSTALL_DIR:-/Applications}
backup_dir=${BACKUP_DIR:-"$HOME/Library/Application Support/VoiceInput/Install Backups"}
expected_id=com.zhijie.VoiceInput
destination="$install_dir/VoiceInput.app"
staging=''
old_moved=0
new_moved=0
committed=0

fail() { printf '%s\n' "$*" >&2; exit 1; }
bundle_id() { /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist"; }
requirement() { /usr/bin/codesign -d -r- "$1" 2>&1 | /usr/bin/sed -n 's/^designated => //p'; }
signature_details() { /usr/bin/codesign -dv --verbose=2 "$1" 2>&1; }

cleanup() {
    status=$?
    if [[ "$committed" == 0 ]]; then
        if [[ "$new_moved" == 1 ]]; then /bin/rm -rf "$destination"; fi
        if [[ "$old_moved" == 1 ]]; then /bin/mv "$staging/previous.app" "$destination"; fi
    fi
    if [[ -n "$staging" && -d "$staging" ]]; then /bin/rm -rf "$staging"; fi
    exit "$status"
}
trap cleanup EXIT

[[ -d "$source_app/Contents" ]] || fail "App bundle not found: $source_app"
[[ -d "$install_dir" ]] || fail "Install directory does not exist: $install_dir"
[[ ! -L "$destination" ]] || fail "Refusing to replace an app symlink: $destination"
[[ "$(bundle_id "$source_app")" == "$expected_id" ]] || fail "Unexpected bundle identifier; keep $expected_id to preserve permissions."
/usr/bin/codesign --verify --deep --strict "$source_app"
new_details=$(signature_details "$source_app")
printf '%s\n' "$new_details" | /usr/bin/grep -q '^Authority=' || fail "Installation requires certificate signing. Ad-hoc builds change identity with every build; run 'make build' with SIGNING_IDENTITY configured."
printf '%s\n' "$new_details" | /usr/bin/grep -Fxq "Identifier=$expected_id" || fail "The signing identifier does not match the app bundle identifier."

executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$source_app/Contents/Info.plist")
# Never interrupt a recording or its pending transcription/refinement. The app
# must be quit normally after finishing work; installation never sends kill/quit.
running=0
if /usr/bin/pgrep -x "$executable" >/dev/null; then
    running=1
    if [[ "${ALLOW_RUNNING_UPDATE:-0}" != 1 ]]; then
        fail "VoiceInput is running. Finish dictation and quit normally, or use ALLOW_RUNNING_UPDATE=1 to leave the current process running and update the next launch. No process was stopped."
    fi
fi

staging=$(/usr/bin/mktemp -d "$install_dir/.voiceinput-install.XXXXXX")
/usr/bin/ditto "$source_app" "$staging/VoiceInput.app"
/usr/bin/codesign --verify --deep --strict "$staging/VoiceInput.app"
requirement "$staging/VoiceInput.app" > "$staging/new.req"
[[ -s "$staging/new.req" ]] || fail "The new app has no designated requirement."

if [[ -e "$destination" ]]; then
    [[ "$(bundle_id "$destination")" == "$expected_id" ]] || fail "Installed bundle identifier differs; refusing replacement."
    /usr/bin/codesign --verify --deep --strict "$destination"
    requirement "$destination" > "$staging/old.req"
    old_details=$(signature_details "$destination")
    if printf '%s\n' "$old_details" | /usr/bin/grep -q '^Signature=adhoc'; then
        printf '%s\n' 'Migrating the old ad-hoc app to a persistent certificate identity. macOS may ask for permissions once after this update; later compatible updates retain the identity.'
    else
        # Require mutual compatibility, not just matching bundle ID or team.
        # This catches accidental certificate/designated-requirement changes.
        [[ -s "$staging/old.req" ]] || fail "Installed app has no designated requirement."
        if ! /usr/bin/codesign --verify --strict -R "$staging/old.req" "$staging/VoiceInput.app" ||
           ! /usr/bin/codesign --verify --strict -R "$staging/new.req" "$destination"; then
            fail "Signing identity changed. Rebuild with the original SIGNING_IDENTITY; the installed app was not changed."
        fi
    fi
    backup="$backup_dir/$(/bin/date '+%Y%m%d-%H%M%S')-$$"
    /bin/mkdir -p "$backup"
    /usr/bin/ditto "$destination" "$backup/VoiceInput.app"
    /bin/cp "$staging/old.req" "$backup/designated-requirement.txt"
    /usr/bin/codesign --verify --deep --strict "$backup/VoiceInput.app"
    printf 'Previous app backed up to %s\n' "$backup/VoiceInput.app"
    /bin/mv "$destination" "$staging/previous.app"
    old_moved=1
fi

/bin/mv "$staging/VoiceInput.app" "$destination"
new_moved=1
/usr/bin/codesign --verify --deep --strict "$destination"
committed=1
printf 'Installed to %s\n' "$destination"
if [[ "$running" == 1 ]]; then
    printf '%s\n' 'The running VoiceInput process was left alone. The update takes effect after your next normal quit and restart.'
fi
