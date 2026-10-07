#!/bin/bash
# Sends a signed app or binary to Apple's notary service and staples the ticket to apps.
# Needs an App Store Connect API key: NOTARY_KEY_PATH (.p8), NOTARY_KEY_ID, NOTARY_ISSUER_ID.
# Usage: scripts/notarize.sh <path to .app or binary>
set -euo pipefail
target="${1:?usage: notarize.sh <path>}"
: "${NOTARY_KEY_PATH:?set NOTARY_KEY_PATH}" "${NOTARY_KEY_ID:?set NOTARY_KEY_ID}" "${NOTARY_ISSUER_ID:?set NOTARY_ISSUER_ID}"

archive="$(mktemp -d)/$(basename "$target").zip"
ditto -c -k --keepParent "$target" "$archive"
xcrun notarytool submit "$archive" --wait \
  --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID"
# Tickets can be stapled to bundles only; a bare binary is checked online when first run.
if [[ "$target" == *.app ]]; then
  xcrun stapler staple "$target"
fi
