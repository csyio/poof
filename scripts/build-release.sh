#!/bin/bash
# Builds a universal (Apple silicon + Intel) poof binary and packages it for a GitHub release.
# Usage: scripts/build-release.sh <version>   e.g. scripts/build-release.sh 0.1.0
set -euo pipefail

version="${1:?usage: build-release.sh <version>}"
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

declared="$(sed -n 's/^public let poofVersion = "\(.*\)"$/\1/p' Sources/PoofCore/Version.swift)"
if [[ "$declared" != "$version" ]]; then
  echo "Version mismatch: tag is $version, Sources/PoofCore/Version.swift says $declared" >&2
  exit 1
fi

build=(swift build -c release --arch arm64 --arch x86_64)
"${build[@]}"
# The output folder differs between Swift versions (.build/apple vs .build/out).
binary="$("${build[@]}" --show-bin-path)/poof"

dist="$root/dist"
rm -rf "$dist" && mkdir -p "$dist/poof-$version"
cp "$binary" README.md LICENSE "$dist/poof-$version/"
tar -C "$dist" -czf "$dist/poof-$version-macos-universal.tar.gz" "poof-$version"
(cd "$dist" && shasum -a 256 "poof-$version-macos-universal.tar.gz" > "poof-$version-macos-universal.tar.gz.sha256")
rm -rf "$dist/poof-$version"

# The app, zipped with ditto so the bundle's signature and metadata survive.
"$root/scripts/build-app.sh" "$dist" > /dev/null
ditto -c -k --keepParent "$dist/Poof.app" "$dist/Poof-$version.zip"
rm -rf "$dist/Poof.app"
(cd "$dist" && shasum -a 256 "Poof-$version.zip" > "Poof-$version.zip.sha256")

lipo -info "$binary"
ls -1 "$dist"
