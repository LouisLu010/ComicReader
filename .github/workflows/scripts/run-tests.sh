#!/usr/bin/env bash

set -euo pipefail

readonly PROJECT="${PROJECT:-ComicReader.xcodeproj}"
readonly SCHEME="${SCHEME:-ComicReader}"
readonly TEST_DESTINATION="${TEST_DESTINATION:-platform=iOS Simulator,name=iPad Pro 13-inch (M4),OS=18.5}"
readonly TEST_DERIVED_DATA="${TEST_DERIVED_DATA:-${RUNNER_TEMP:?RUNNER_TEMP is required}/ComicReaderTestDerivedData}"
readonly RESULT_BUNDLE="${RESULT_BUNDLE:-${RUNNER_TEMP:?RUNNER_TEMP is required}/ComicReaderTests-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}.xcresult}"

if [[ ! -d "$PROJECT" ]]; then
  echo "::error title=Missing Xcode project::$PROJECT was not found."
  exit 1
fi

xcode_version="$(xcodebuild -version)"
xcode_major="$(printf '%s\n' "$xcode_version" | awk 'NR == 1 { split($2, version, "."); print version[1] }')"

if [[ "$xcode_major" != "16" ]]; then
  echo "::error title=Unexpected Xcode version::Expected Xcode 16, got: ${xcode_version//$'\n'/ }"
  exit 1
fi

printf '%s\n' "$xcode_version"
swift --version

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -resolvePackageDependencies

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination "$TEST_DESTINATION" \
  -derivedDataPath "$TEST_DERIVED_DATA" \
  -enableCodeCoverage YES \
  -disableAutomaticPackageResolution \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build-for-testing

readonly TEST_APP_PATH="$TEST_DERIVED_DATA/Build/Products/Debug-iphonesimulator/ComicReader.app"
readonly TEST_PRIVACY_MANIFEST="$TEST_APP_PATH/PrivacyInfo.xcprivacy"

if [[ ! -f "$TEST_PRIVACY_MANIFEST" ]]; then
  echo "::error title=Missing privacy manifest::Expected $TEST_PRIVACY_MANIFEST in the app bundle."
  exit 1
fi

/usr/bin/plutil -lint "$TEST_PRIVACY_MANIFEST"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination "$TEST_DESTINATION" \
  -derivedDataPath "$TEST_DERIVED_DATA" \
  -enableCodeCoverage YES \
  -disableAutomaticPackageResolution \
  -parallel-testing-enabled NO \
  -resultBundlePath "$RESULT_BUNDLE" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  test-without-building
