#!/usr/bin/env bash

set -euo pipefail

readonly XCODEGEN_VERSION="2.45.4"
readonly XCODEGEN_SHA256="090ec29491aad50aec10631bf6e62253fed733c50f3aab0f5ffc86bc170bdbef"
readonly XCODEGEN_URL="https://github.com/yonaskolb/XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip"
readonly XCODEGEN_ARCHIVE="${RUNNER_TEMP:?RUNNER_TEMP is required}/xcodegen-${XCODEGEN_VERSION}.zip"
readonly XCODEGEN_INSTALL_ROOT="${RUNNER_TEMP:?RUNNER_TEMP is required}/xcodegen-${XCODEGEN_VERSION}"
readonly XCODEGEN_BINARY="$XCODEGEN_INSTALL_ROOT/xcodegen/bin/xcodegen"

if [[ ! -f "project.yml" ]]; then
  echo "::error title=Missing XcodeGen spec::project.yml was not found."
  exit 1
fi

if [[ -n "$(git ls-files 'ComicReader.xcodeproj/**')" ]]; then
  echo "::error title=Generated project is tracked::ComicReader.xcodeproj must be generated from project.yml, not committed."
  exit 1
fi

curl \
  --fail \
  --location \
  --silent \
  --show-error \
  --retry 3 \
  --proto "=https" \
  --tlsv1.2 \
  "$XCODEGEN_URL" \
  --output "$XCODEGEN_ARCHIVE"

actual_sha256="$(/usr/bin/shasum -a 256 "$XCODEGEN_ARCHIVE" | awk '{ print $1 }')"

if [[ "$actual_sha256" != "$XCODEGEN_SHA256" ]]; then
  echo "::error title=XcodeGen checksum mismatch::Expected $XCODEGEN_SHA256, got $actual_sha256."
  exit 1
fi

mkdir -p "$XCODEGEN_INSTALL_ROOT"
/usr/bin/ditto -x -k "$XCODEGEN_ARCHIVE" "$XCODEGEN_INSTALL_ROOT"

if [[ ! -x "$XCODEGEN_BINARY" ]]; then
  echo "::error title=Missing XcodeGen binary::The verified archive did not contain the expected executable."
  exit 1
fi

"$XCODEGEN_BINARY" --version
"$XCODEGEN_BINARY" generate --spec project.yml

if [[ ! -d "ComicReader.xcodeproj" ]]; then
  echo "::error title=Project generation failed::ComicReader.xcodeproj was not generated."
  exit 1
fi

printf '%s\n' "$(dirname "$XCODEGEN_BINARY")" >> "${GITHUB_PATH:?GITHUB_PATH is required}"
