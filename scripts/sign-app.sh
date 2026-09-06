#!/bin/bash
# Sign local builds with a persistent certificate identity so TCC can match updates.
set -euo pipefail

app=${1:-VoiceInput.app}
identity=${SIGNING_IDENTITY:-}
allow_adhoc=${ALLOW_ADHOC:-0}

fail() { printf '%s\n' "$*" >&2; exit 1; }
[[ -d "$app/Contents" ]] || fail "App bundle not found: $app"

if [[ -z "$identity" ]]; then
    # Only use an unambiguous application-signing identity. Never pick whichever
    # certificate happens to appear first, or silently fall back to ad-hoc.
    identities=$(/usr/bin/security find-identity -v -p codesigning) || fail "Cannot read code-signing identities from the keychain."
    candidates=$(printf '%s\n' "$identities" | /usr/bin/awk '
        /"Apple Development:|"Developer ID Application:|"Mac Developer:/ && $2 ~ /^[0-9A-Fa-f]+$/ && length($2) == 40 { print $2 }')
    count=$(printf '%s\n' "$candidates" | /usr/bin/awk 'NF { n++ } END { print n+0 }')
    if [[ "$count" == 1 ]]; then
        identity=$candidates
    else
        fail "Set SIGNING_IDENTITY to a certificate SHA-1 in .signing.local.mk (found $count usable identities). Use 'security find-identity -v -p codesigning' to choose. For a disposable local build only, use 'make dev-build'."
    fi
fi

if [[ "$identity" == '-' && "$allow_adhoc" != 1 ]]; then
    fail "Ad-hoc signing needs explicit ALLOW_ADHOC=1; it cannot preserve permissions across builds."
fi

# Keep the current local-app runtime behavior. Adding hardened runtime here
# would require auditing entitlements for microphone/Apple Events separately.
/usr/bin/codesign --force --sign "$identity" --timestamp=none "$app"
/usr/bin/codesign --verify --deep --strict "$app"
if [[ "$identity" == '-' ]]; then
    printf '%s\n' 'Built an ad-hoc development app. make install will reject this signature.'
else
    printf 'Signed %s with identity %s\n' "$app" "$identity"
fi
