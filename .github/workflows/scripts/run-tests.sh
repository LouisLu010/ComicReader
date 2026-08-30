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
# 2. 若首选的 iPad 模拟器设备不存在，则用最新 iOS 运行时
#    创建一台，并以其版本作为测试目标。
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

latest_ios_runtime_version() {
  xcrun simctl list runtimes available |
    grep '^iOS ' | sort -V | tail -1 |
    sed -E 's/^iOS ([0-9.]+).*$/\1/'
}

ensure_ipad_device() {
  local preferred_name="iPad Pro 13-inch (M4)"
  if xcrun simctl list devices available | grep -qF "$preferred_name"; then
    return
  fi

  local device_type runtime
  device_type="$(xcrun simctl list devicetypes |
    grep -F "$preferred_name" | tail -1 |
    sed -E 's/.*\((com\.apple[^)]*)\).*/\1/')"
  runtime="$(xcrun simctl list runtimes available |
    grep '^iOS ' | sort -V | tail -1 |
    sed -E 's/.*(com\.apple\.CoreSimulator\.SimRuntime[^ ]*).*/\1/')"

  if [[ -z "$device_type" || -z "$runtime" ]]; then
    echo "::error title=No iPad simulator::No iPad device type or iOS runtime is available."
    exit 1
  fi

  echo "Creating simulator device: $preferred_name ($runtime)"
  xcrun simctl create "$preferred_name" "$device_type" "$runtime"
}

resolve_test_destination() {
  ensure_ipad_device

  local preferred_name="iPad Pro 13-inch (M4)"
  local preferred_os="18.5"
  local preferred_runtime
  preferred_runtime="$(xcrun simctl list runtimes available |
    grep -F "iOS $preferred_os" | head -1)"
  if [[ -n "$preferred_runtime" ]] && xcrun simctl list devices available |
    grep -qF "$preferred_name"; then
    printf 'platform=iOS Simulator,name=%s,OS=%s' \
      "$preferred_name" "$preferred_os"
    return
  fi

  local runtime_version
  runtime_version="$(latest_ios_runtime_version)"
  printf 'platform=iOS Simulator,name=%s,OS=%s' \
    "$preferred_name" "$runtime_version"
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
