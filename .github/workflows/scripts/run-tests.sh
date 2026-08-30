#!/usr/bin/env bash

set -euo pipefail

readonly PROJECT="${PROJECT:-ComicReader.xcodeproj}"
readonly SCHEME="${SCHEME:-ComicReader}"
readonly PREFERRED_TEST_DESTINATION="${TEST_DESTINATION:-platform=iOS Simulator,name=iPad Pro 13-inch (M4),OS=18.5}"
readonly TEST_DERIVED_DATA="${TEST_DERIVED_DATA:-${RUNNER_TEMP:?RUNNER_TEMP is required}/ComicReaderTestDerivedData}"
readonly RESULT_BUNDLE="${RESULT_BUNDLE:-${RUNNER_TEMP:?RUNNER_TEMP is required}/ComicReaderTests-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}.xcresult}"

if [[ ! -d "$PROJECT" ]]; then
  echo "::error title=Missing Xcode project::$PROJECT was not found."
  exit 1
fi

# GitHub 会随镜像更新替换可用的 Xcode 与模拟器运行时，因此：
# 1. 若首选 Xcode 缺少可用的 iOS 模拟器运行时，改用镜像上
#    自带 iOS 运行时的最新 Xcode；
# 2. 测试目标优先使用固定 destination，不可用时回退到该
#    Xcode 下运行时最新的 iPad 模拟器。
has_ios_runtime() {
  xcrun --developer-dir "$1" simctl list runtimes available 2>/dev/null |
    grep -q '^iOS '
}

select_developer_dir() {
  local preferred="${DEVELOPER_DIR:-}"
  if [[ -n "$preferred" ]] && has_ios_runtime "$preferred"; then
    printf '%s' "$preferred"
    return
  fi

  local candidate
  while IFS= read -r candidate; do
    if has_ios_runtime "$candidate/Contents/Developer"; then
      printf '%s' "$candidate/Contents/Developer"
      return
    fi
  done < <(ls -d /Applications/Xcode*.app 2>/dev/null | sort -r)

  printf '%s' "$preferred"
}

export DEVELOPER_DIR="$(select_developer_dir)"
echo "Using DEVELOPER_DIR: $DEVELOPER_DIR"

resolve_test_destination() {
  local preferred_name
  preferred_name="$(printf '%s' "$PREFERRED_TEST_DESTINATION" |
    sed -E 's/.*name=([^,]+).*/\1/')"
  local preferred_os
  preferred_os="$(printf '%s' "$PREFERRED_TEST_DESTINATION" |
    sed -E 's/.*OS=([^,]+).*/\1/')"

  local available
  available="$(xcodebuild -showdestinations \
    -project "$PROJECT" -scheme "$SCHEME" 2>/dev/null |
    grep 'platform:iOS Simulator' || true)"

  if printf '%s\n' "$available" | grep -qF "name:$preferred_name" \
    && printf '%s\n' "$available" | grep -qF "OS:$preferred_os"; then
    printf '%s' "$PREFERRED_TEST_DESTINATION"
    return
  fi

  local fallback_line
  fallback_line="$(printf '%s\n' "$available" |
    grep -F 'name:iPad' | sort -V | tail -1)"
  if [[ -z "$fallback_line" ]]; then
    echo "::error title=No iPad simulator::No available iPad simulator destination was found."
    exit 1
  fi

  local fallback_os fallback_name
  fallback_os="$(printf '%s' "$fallback_line" | sed -E 's/.*OS:([^,]+).*/\1/')"
  fallback_name="$(printf '%s' "$fallback_line" | sed -E 's/.*name:([^,]+).*/\1/')"
  printf 'platform=iOS Simulator,name=%s,OS=%s' "$fallback_name" "$fallback_os"
}

readonly TEST_DESTINATION="$(resolve_test_destination)"
echo "Using test destination: $TEST_DESTINATION"

xcode_version="$(xcodebuild -version)"
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
