#!/usr/bin/env bash
# Vita3KiOS: configures, builds and packages the iOS app as an unsigned (fake-signed) IPA.
#
# Usage: .ci/build-ios.sh <output-dir>
# Needs: Xcode, cmake, ninja, ccache, ldid, and VCPKG_ROOT pointing at a bootstrapped vcpkg.
set -euo pipefail

output_dir="${1:-artifacts}"
build_type="${BUILD_CONFIG:-Release}"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${repo_root}/build/ios"

: "${VCPKG_ROOT:?VCPKG_ROOT must point at a bootstrapped vcpkg checkout}"

cmake -S "$repo_root" -B "$build_dir" -G Ninja \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_SYSTEM_PROCESSOR=arm64 \
    -DCMAKE_BUILD_TYPE="$build_type" \
    -DCMAKE_TOOLCHAIN_FILE="${VCPKG_ROOT}/scripts/buildsystems/vcpkg.cmake" \
    -DVCPKG_TARGET_TRIPLET=arm64-ios \
    -DCMAKE_C_COMPILER_LAUNCHER=ccache \
    -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
    -DCMAKE_OBJC_COMPILER_LAUNCHER=ccache \
    -DCMAKE_OBJCXX_COMPILER_LAUNCHER=ccache \
    -DUSE_LTO=NEVER \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5

# -k 0 keeps going after the first failure, so one CI run reports every broken file at once
cmake --build "$build_dir" --target vita3k -- -k 0

app_path="$(find "$build_dir" -maxdepth 3 -name 'Vita3K.app' -type d | head -n 1)"
if [[ -z "$app_path" ]]; then
    echo "Vita3K.app not found under $build_dir" >&2
    exit 1
fi
echo "Built app bundle: $app_path"

# Fake-sign so the entitlements (get-task-allow for StikDebug, memory limits) are embedded.
# AltStore/SideStore re-sign with the user's own certificate when installing.
ldid -S"${repo_root}/vita3k/ios/Vita3K.entitlements" "$app_path/Vita3K"

mkdir -p "$output_dir"
staging="$(mktemp -d)"
mkdir -p "$staging/Payload"
cp -R "$app_path" "$staging/Payload/"
short_sha="$(git -C "$repo_root" rev-parse --short HEAD)"
ipa_name="Vita3K-iOS-${short_sha}.ipa"
(cd "$staging" && zip -qry "$ipa_name" Payload)
mv "$staging/$ipa_name" "$output_dir/"
rm -rf "$staging"

echo "IPA: $output_dir/$ipa_name"
if [[ -n "${GITHUB_ENV:-}" ]]; then
    echo "IPA_PATH=$output_dir/$ipa_name" >> "$GITHUB_ENV"
    echo "IPA_NAME=${ipa_name%.ipa}" >> "$GITHUB_ENV"
fi
