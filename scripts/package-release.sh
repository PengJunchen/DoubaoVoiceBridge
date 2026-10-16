#!/bin/bash
set -euo pipefail

bundle_id="com.lyp.DoubaoVoiceBridge"
app_name="远控听写·自动适配.app"
executable_name="DoubaoVoiceBridge"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
project_root="$(cd "$script_dir/.." && pwd -P)"
source_app="dist/$app_name"
output_dir="outdist"
run_self_test=false

fail() {
    printf 'package-release: %s\n' "$1" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: scripts/package-release.sh [--project-root PATH] [--app PATH] [--out-dir PATH] [--self-test]

Create arm64, x86_64, and universal ZIPs from an already-built universal .app.
Relative paths are resolved from --project-root. The app is never modified.
EOF
}

while (($#)); do
    case "$1" in
        --project-root)
            (($# >= 2)) || fail "--project-root requires a path"
            project_root="$2"
            shift 2
            ;;
        --app)
            (($# >= 2)) || fail "--app requires a path"
            source_app="$2"
            shift 2
            ;;
        --out-dir)
            (($# >= 2)) || fail "--out-dir requires a path"
            output_dir="$2"
            shift 2
            ;;
        --self-test)
            run_self_test=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            fail "unknown option: $1"
            ;;
    esac
done

[[ -d "$project_root" ]] || fail "project root does not exist: $project_root"
project_root="$(cd "$project_root" && pwd -P)"
if [[ "$source_app" != /* ]]; then
    source_app="$project_root/$source_app"
fi
if [[ "$output_dir" != /* ]]; then
    output_dir="$project_root/$output_dir"
fi
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd -P)"

[[ -d "$source_app" && ! -L "$source_app" ]] || fail "input must be a real .app directory: $source_app"
[[ "$source_app" == *.app ]] || fail "input path must end in .app"
source_app="$(cd "$source_app" && pwd -P)"
[[ -f "$project_root/LICENSE" && ! -L "$project_root/LICENSE" ]] || fail "project LICENSE is missing or not a regular file"
project_info="$project_root/Resources/Info.plist"
[[ -f "$project_info" && ! -L "$project_info" ]] || fail "project Info.plist is missing or not a regular file"
plutil -lint "$project_info" >/dev/null || fail "project Info.plist is invalid"

source_info="$source_app/Contents/Info.plist"
source_binary="$source_app/Contents/MacOS/$executable_name"
source_license="$source_app/Contents/Resources/LICENSE"
[[ -f "$source_info" && ! -L "$source_info" ]] || fail "app Info.plist is missing or not a regular file"
[[ -f "$source_binary" && ! -L "$source_binary" ]] || fail "app executable is missing or not a regular file"
[[ -f "$source_license" && ! -L "$source_license" ]] || fail "bundled LICENSE is missing or not a regular file"
cmp -s "$project_root/LICENSE" "$source_license" || fail "bundled LICENSE does not match project LICENSE"
plutil -lint "$source_info" >/dev/null || fail "app Info.plist is invalid"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$source_info")"
app_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$source_info")"
app_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$source_info")"
project_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_info")"
project_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$project_info")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "app version must use X.Y.Z"
[[ "$app_bundle_id" == "$bundle_id" ]] || fail "unexpected bundle identifier: $app_bundle_id"
[[ "$app_executable" == "$executable_name" ]] || fail "unexpected app executable: $app_executable"
[[ "$project_version" == "$version" ]] || fail "app version does not match project Info.plist"
[[ "$project_bundle_id" == "$bundle_id" ]] || fail "unexpected project bundle identifier: $project_bundle_id"

verify_app() {
    local app_path="$1"
    local expected_arch="$2"
    local info_path="$app_path/Contents/Info.plist"
    local binary_path="$app_path/Contents/MacOS/$executable_name"
    local license_path="$app_path/Contents/Resources/LICENSE"
    local actual_version actual_bundle_id actual_executable actual_archs
    local signature_details requirement_details

    [[ -f "$info_path" && ! -L "$info_path" ]] || fail "missing Info.plist in $app_path"
    [[ -f "$binary_path" && ! -L "$binary_path" ]] || fail "missing executable in $app_path"
    [[ -f "$license_path" && ! -L "$license_path" ]] || fail "missing LICENSE in $app_path"
    cmp -s "$project_root/LICENSE" "$license_path" || fail "LICENSE mismatch in $app_path"
    plutil -lint "$info_path" >/dev/null || fail "invalid Info.plist in $app_path"

    actual_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_path")"
    actual_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_path")"
    actual_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info_path")"
    [[ "$actual_version" == "$version" ]] || fail "version changed in $app_path"
    [[ "$actual_bundle_id" == "$bundle_id" ]] || fail "bundle identifier changed in $app_path"
    [[ "$actual_executable" == "$executable_name" ]] || fail "executable name changed in $app_path"

    codesign --verify --deep --strict --verbose=2 "$app_path" || fail "strict signature verification failed for $app_path"
    signature_details="$(codesign -dv --verbose=4 "$app_path" 2>&1)" || fail "cannot read signature for $app_path"
    case "$signature_details" in
        *"Signature=adhoc"*) ;;
        *) fail "expected an ad-hoc signature for $app_path" ;;
    esac
    requirement_details="$(codesign -d -r- "$app_path" 2>&1)" || fail "cannot read designated requirement for $app_path"
    case "$requirement_details" in
        *"designated => identifier \"$bundle_id\""*) ;;
        *) fail "unexpected designated requirement for $app_path" ;;
    esac

    actual_archs="$(lipo -archs "$binary_path")"
    [[ "$actual_archs" == "$expected_arch" ]] || fail "expected only $expected_arch in $app_path; found: $actual_archs"
}

source_archs="$(lipo -archs "$source_binary")"
case "$source_archs" in
    "arm64 x86_64"|"x86_64 arm64") ;;
    *) fail "input must contain exactly arm64 and x86_64; found: $source_archs" ;;
esac
verify_app "$source_app" "$source_archs"

work_root="$(mktemp -d "${TMPDIR:-/tmp}/doubao-release.XXXXXX")"
archive_dir="$(mktemp -d "$output_dir/.fork-release.XXXXXX")"
cleanup() {
    rm -rf "$work_root" "$archive_dir"
}
trap cleanup EXIT

universal_app="$work_root/universal/$app_name"
mkdir -p "$(dirname "$universal_app")"
ditto "$source_app" "$universal_app"
verify_app "$universal_app" "$source_archs"

for architecture in arm64 x86_64; do
    thin_app="$work_root/$architecture/$app_name"
    mkdir -p "$(dirname "$thin_app")"
    ditto "$source_app" "$thin_app"
    rm "$thin_app/Contents/MacOS/$executable_name"
    lipo -thin "$architecture" "$source_binary" -output "$thin_app/Contents/MacOS/$executable_name"
    chmod 755 "$thin_app/Contents/MacOS/$executable_name"
    codesign --force --sign - \
        --identifier "$bundle_id" \
        --requirements '=designated => identifier "com.lyp.DoubaoVoiceBridge"' \
        "$thin_app"
    verify_app "$thin_app" "$architecture"
done

if [[ "$run_self_test" == true ]]; then
    if [[ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" == "1" ]]; then
        host_arch="arm64"
    else
        host_arch="$(uname -m)"
    fi
    case "$host_arch" in
        arm64|x86_64) ;;
        *) fail "--self-test supports only Apple Silicon or Intel macOS hosts; found: $host_arch" ;;
    esac
    printf 'Running --self-test on the host-matching %s package.\n' "$host_arch"
    arch "-$host_arch" "$work_root/$host_arch/$app_name/Contents/MacOS/$executable_name" --self-test
fi

for architecture in arm64 x86_64 universal; do
    zip_name="DoubaoVoiceBridge-macOS-${architecture}-v${version}.zip"
    checksum_name="$zip_name.sha256"
    final_zip="$output_dir/$zip_name"
    final_checksum="$output_dir/$checksum_name"
    [[ ! -e "$final_zip" && ! -e "$final_checksum" ]] || fail "refusing to overwrite existing output for $architecture"

    case "$architecture" in
        universal) app_to_package="$universal_app" ;;
        *) app_to_package="$work_root/$architecture/$app_name" ;;
    esac
    ditto -c -k --sequesterRsrc --keepParent "$app_to_package" "$archive_dir/$zip_name"
    (
        cd "$archive_dir"
        shasum -a 256 "$zip_name" > "$checksum_name"
        shasum -a 256 -c "$checksum_name"
    )
done

for architecture in arm64 x86_64 universal; do
    zip_name="DoubaoVoiceBridge-macOS-${architecture}-v${version}.zip"
    mv "$archive_dir/$zip_name" "$output_dir/$zip_name"
    mv "$archive_dir/$zip_name.sha256" "$output_dir/$zip_name.sha256"
done

printf 'Created release packages for v%s in %s\n' "$version" "$output_dir"
