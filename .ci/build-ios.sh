#!/usr/bin/env bash
# Vita3KiOS: builds an unsigned IPA with a plain Xcode project.
#   1. CMake generates Vita3K.xcodeproj
#   2. xcodebuild builds it (no signing)
#   3. the .app is zipped into Payload/ as an .ipa
# Sign/install it with AltStore, SideStore, LiveContainer, TrollStore, etc.
#
# Usage: .ci/build-ios.sh <output-dir>
set -euo pipefail

output_dir="${1:-artifacts}"
config="${BUILD_CONFIG:-Release}"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${repo_root}/build/ios"

: "${VCPKG_ROOT:?VCPKG_ROOT must point at a bootstrapped vcpkg checkout}"

cmake -S "$repo_root" -B "$build_dir" -G Xcode \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_SYSTEM_PROCESSOR=arm64 \
    -DCMAKE_TOOLCHAIN_FILE="${VCPKG_ROOT}/scripts/buildsystems/vcpkg.cmake" \
    -DVCPKG_TARGET_TRIPLET=arm64-ios \
    -DUSE_LTO=NEVER \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5

xcodebuild \
    -project "$build_dir/Vita3K.xcodeproj" \
    -target vita3k \
    -configuration "$config" \
    -sdk iphoneos \
    -parallelizeTargets \
    -jobs "$(sysctl -n hw.ncpu)" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    build

app_path="$(find "$build_dir" -name 'Vita3K.app' -type d -path "*${config}-iphoneos*" | head -n 1)"
if [[ -z "$app_path" ]]; then
    echo "Vita3K.app not found under $build_dir" >&2
    exit 1
fi
echo "Built: $app_path"

mkdir -p "$output_dir"
staging="$(mktemp -d)"
mkdir -p "$staging/Payload"
cp -R "$app_path" "$staging/Payload/"
ipa_name="Vita3K-iOS-$(git -C "$repo_root" rev-parse --short HEAD).ipa"
(cd "$staging" && zip -qry "$ipa_name" Payload)
mv "$staging/$ipa_name" "$output_dir/"
rm -rf "$staging"

echo "IPA: $output_dir/$ipa_name"
if [[ -n "${GITHUB_ENV:-}" ]]; then
    echo "IPA_PATH=$output_dir/$ipa_name" >> "$GITHUB_ENV"
    echo "IPA_NAME=${ipa_name%.ipa}" >> "$GITHUB_ENV"
fi
