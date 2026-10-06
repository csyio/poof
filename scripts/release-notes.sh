#!/bin/bash
# Prints the CHANGELOG.md section for one version, used as the GitHub release body.
# Usage: scripts/release-notes.sh <version>
set -euo pipefail
version="${1:?usage: release-notes.sh <version>}"
awk -v v="$version" '
  $0 ~ "^## \\[" v "\\]" { found = 1; next }
  found && /^## \[/ { exit }
  found { print }
' "$(dirname "$0")/../CHANGELOG.md" | sed -e '/./,$!d'
