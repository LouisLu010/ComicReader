#!/usr/bin/env bash

set -euo pipefail

readonly PROJECT="${PROJECT:-ComicReader.xcodeproj}"
readonly SCHEME="${SCHEME:-ComicReader}"
readonly ARTIFACT_LABEL="${ARTIFACT_LABEL:-${GITHUB_REF_NAME:-local}}"
readonly DERIVED_DATA="${RELEASE_DERIVED_DATA:-${RUNNER_TEMP:?RUNNER_TEMP is required}/ComicReaderReleaseDerivedData}"
readonly DIST_DIR="${DIST_DIR:-${RUNNER_TEMP:?RUNNER_TEMP is required}/ComicReaderArtifacts}"
readonly SETTINGS_JSON="${RUNNER_TEMP:?RUNNER_TEMP is required}/ComicReaderBuildSettings.json"
readonly STAGING_DIR="${RUNNER_TEMP:?RUNNER_TEMP is required}/ComicReaderIPAStaging"

if [[ ! -d "$PROJECT" ]]; then
  echo "::error title=Missing Xcode project::$PROJECT was not found."
  exit 1
fi

safe_label="$(printf '%s' "$ARTIFACT_LABEL" | tr -c 'A-Za-z0-9._-' '-')"

if [[ -z "$safe_label" ]]; then
  echo "::error title=Invalid artifact label::The artifact label is empty after sanitization."
  exit 1
fi

mkdir -p "$DIST_DIR" "$STAGING_DIR/Payload"

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -sdk iphoneos \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$DERIVED_DATA" \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY= \
  PROVISIONING_PROFILE_SPECIFIER= \
  DEBUG_INFORMATION_FORMAT=dwarf-with-dsym \
  build

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -sdk iphoneos \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$DERIVED_DATA" \
  -disableAutomaticPackageResolution \
  -showBuildSettings \
  -json > "$SETTINGS_JSON"

app_settings="$(
  jq -c \
    '[.[] | select(.buildSettings.PRODUCT_TYPE == "com.apple.product-type.application")][0].buildSettings' \
    "$SETTINGS_JSON"
)"

if [[ -z "$app_settings" || "$app_settings" == "null" ]]; then
  echo "::error title=Missing application target::No application build settings were found for $SCHEME."
  exit 1
fi

full_product_name="$(jq -r '.FULL_PRODUCT_NAME' <<< "$app_settings")"
target_build_dir="$(jq -r '.TARGET_BUILD_DIR' <<< "$app_settings")"
dsym_file_name="$(jq -r '.DWARF_DSYM_FILE_NAME' <<< "$app_settings")"
dsym_folder_path="$(jq -r '.DWARF_DSYM_FOLDER_PATH' <<< "$app_settings")"
app_version="$(jq -r '.MARKETING_VERSION' <<< "$app_settings")"
build_number="$(jq -r '.CURRENT_PROJECT_VERSION' <<< "$app_settings")"
bundle_identifier="$(jq -r '.PRODUCT_BUNDLE_IDENTIFIER' <<< "$app_settings")"
deployment_target="$(jq -r '.IPHONEOS_DEPLOYMENT_TARGET' <<< "$app_settings")"
targeted_device_family="$(jq -r '.TARGETED_DEVICE_FAMILY' <<< "$app_settings" | tr -d '" ')"

readonly APP_PATH="$target_build_dir/$full_product_name"
readonly DSYM_PATH="$dsym_folder_path/$dsym_file_name"

if [[ ! -d "$APP_PATH" ]]; then
  echo "::error title=Missing app product::Expected app product at $APP_PATH."
  exit 1
fi

if [[ ! -d "$DSYM_PATH" ]]; then
  echo "::error title=Missing dSYM::Expected dSYM at $DSYM_PATH."
  exit 1
fi

if [[ "$deployment_target" != "17.0" ]]; then
  echo "::error title=Unexpected deployment target::Expected iPadOS 17.0, got $deployment_target."
  exit 1
fi

if [[ "$targeted_device_family" != "2" ]]; then
  echo "::error title=Unexpected device family::Expected iPad-only TARGETED_DEVICE_FAMILY=2, got $targeted_device_family."
  exit 1
fi

if /usr/bin/codesign --verify "$APP_PATH" >/dev/null 2>&1; then
  echo "::error title=Signed app detected::The Release app must remain unsigned."
  exit 1
fi

if [[ -e "$APP_PATH/embedded.mobileprovision" ]]; then
  echo "::error title=Provisioning profile detected::Unsigned artifacts must not contain embedded.mobileprovision."
  exit 1
fi

/usr/bin/ditto "$APP_PATH" "$STAGING_DIR/Payload/$full_product_name"

readonly IPA_NAME="ComicReader-${safe_label}-unsigned.ipa"
readonly DSYM_ARCHIVE_NAME="ComicReader-${safe_label}.dSYM.zip"
readonly BUILD_INFO_NAME="ComicReader-${safe_label}-build-info.txt"
readonly CHECKSUM_NAME="ComicReader-${safe_label}-SHA256SUMS.txt"

/usr/bin/ditto \
  -c \
  -k \
  --sequesterRsrc \
  --keepParent \
  "$STAGING_DIR/Payload" \
  "$DIST_DIR/$IPA_NAME"

/usr/bin/ditto \
  -c \
  -k \
  --sequesterRsrc \
  --keepParent \
  "$DSYM_PATH" \
  "$DIST_DIR/$DSYM_ARCHIVE_NAME"

(
  cd "$DIST_DIR"
  /usr/bin/shasum -a 256 "$IPA_NAME" "$DSYM_ARCHIVE_NAME" > "$CHECKSUM_NAME"
)

ipa_sha256="$(awk 'NR == 1 { print $1 }' "$DIST_DIR/$CHECKSUM_NAME")"
dsym_sha256="$(awk 'NR == 2 { print $1 }' "$DIST_DIR/$CHECKSUM_NAME")"

package_resolved_digest="none"
package_digest_input="${RUNNER_TEMP:?RUNNER_TEMP is required}/ComicReaderPackageResolved.sha256"
git ls-files '*Package.resolved' | LC_ALL=C sort | while IFS= read -r package_file; do
  printf '%s  %s\n' "$(/usr/bin/shasum -a 256 "$package_file" | awk '{ print $1 }')" "$package_file"
done > "$package_digest_input"

if [[ -s "$package_digest_input" ]]; then
  package_resolved_digest="$(/usr/bin/shasum -a 256 "$package_digest_input" | awk '{ print $1 }')"
fi

build_utc="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
xcode_version="$(xcodebuild -version | tr '\n' ';' | sed 's/;$//')"
swift_version="$(swift --version | awk 'NR == 1')"
xcodegen_version="$(xcodegen --version | awk 'NR == 1')"

{
  printf 'format_version=1\n'
  printf 'unsigned=true\n'
  printf 'artifact_label=%s\n' "$safe_label"
  printf 'app_version=%s\n' "$app_version"
  printf 'build_number=%s\n' "$build_number"
  printf 'bundle_identifier=%s\n' "$bundle_identifier"
  printf 'minimum_ipados=%s\n' "$deployment_target"
  printf 'targeted_device_family=%s\n' "$targeted_device_family"
  printf 'git_commit=%s\n' "${GITHUB_SHA:-unknown}"
  printf 'git_ref_type=%s\n' "${GITHUB_REF_TYPE:-unknown}"
  printf 'git_ref_name=%s\n' "${GITHUB_REF_NAME:-unknown}"
  printf 'build_utc=%s\n' "$build_utc"
  printf 'xcode_version=%s\n' "$xcode_version"
  printf 'swift_version=%s\n' "$swift_version"
  printf 'xcodegen_version=%s\n' "$xcodegen_version"
  printf 'package_resolved_digest=%s\n' "$package_resolved_digest"
  printf 'ipa_sha256=%s\n' "$ipa_sha256"
  printf 'dsym_sha256=%s\n' "$dsym_sha256"
} > "$DIST_DIR/$BUILD_INFO_NAME"

printf 'Created unsigned artifacts in %s\n' "$DIST_DIR"
