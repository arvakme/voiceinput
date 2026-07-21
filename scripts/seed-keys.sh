#!/usr/bin/env bash
# seed-keys.sh — Read .env.local and write API keys to UserDefaults.
# Usage: bash scripts/seed-keys.sh
# Never store keys in source or git — .env.local is gitignored.

set -euo pipefail

ENV_FILE="$(dirname "$0")/../.env.local"

if [ ! -f "$ENV_FILE" ]; then
    echo "Error: .env.local not found at $ENV_FILE" >&2
    exit 1
fi

# Source the file to pick up KEY=VALUE pairs (lines starting with # are ignored by bash sourcing).
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

BUNDLE_ID="com.zhijie.VoiceInput"

if [ -n "${SONIOX_API_KEY:-}" ]; then
    defaults write "$BUNDLE_ID" sonioxAPIKey "$SONIOX_API_KEY"
    echo "Written sonioxAPIKey to $BUNDLE_ID defaults."
else
    echo "SONIOX_API_KEY not set in .env.local — skipping sonioxAPIKey."
fi

POLISH_KEY="${OPENROUTER_API_KEY:-${POLISH_API_KEY:-}}"
if [ -n "$POLISH_KEY" ]; then
    defaults write "$BUNDLE_ID" polishAPIKey "$POLISH_KEY"
    echo "Written polishAPIKey to $BUNDLE_ID defaults."
else
    echo "OPENROUTER_API_KEY not set in .env.local — skipping polishAPIKey."
fi

if [ -n "${QWEN_API_KEY:-}" ]; then
    defaults write "$BUNDLE_ID" qwenAPIKey "$QWEN_API_KEY"
    echo "Written qwenAPIKey to $BUNDLE_ID defaults."
else
    echo "QWEN_API_KEY not set in .env.local — skipping qwenAPIKey."
fi

if [ -n "${QWEN_BASE_URL:-}" ]; then
    defaults write "$BUNDLE_ID" qwenBaseURL "$QWEN_BASE_URL"
    echo "Written qwenBaseURL to $BUNDLE_ID defaults."
else
    echo "QWEN_BASE_URL not set in .env.local — skipping qwenBaseURL."
fi

if [ -n "${QWEN_MODEL:-}" ]; then
    defaults write "$BUNDLE_ID" qwenModel "$QWEN_MODEL"
    echo "Written qwenModel to $BUNDLE_ID defaults."
else
    echo "QWEN_MODEL not set in .env.local — skipping qwenModel."
fi

echo "Done."
