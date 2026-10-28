#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
mkdir -p build dist
/usr/bin/python3 scripts/generate_project.py
if ! /usr/bin/xcodebuild -project Hongguo.xcodeproj -scheme Hongguo \
    -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
    -derivedDataPath "$TASK_ROOT/build/DerivedData" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' \
    build > build/release-build.log 2>&1; then
    tail -100 build/release-build.log
    exit 1
fi
TASK_APP="$TASK_ROOT/build/DerivedData/Build/Products/Release-iphoneos/Hongguo.app"
TASK_PACKAGE="$(mktemp -d "$TASK_ROOT/build/package.XXXXXX")"
trap 'rm -rf "$TASK_PACKAGE"' EXIT
mkdir -p "$TASK_PACKAGE/Payload"
/usr/bin/ditto "$TASK_APP" "$TASK_PACKAGE/Payload/Hongguo.app"
TASK_IPA="$TASK_ROOT/dist/Hongguo-iOS-0.1.0-unsigned.ipa"
TASK_ZIP_TMP="$TASK_PACKAGE/package.zip"
(cd "$TASK_PACKAGE" && COPYFILE_DISABLE=1 /usr/bin/zip -qry "$TASK_ZIP_TMP" Payload)
mv "$TASK_ZIP_TMP" "$TASK_IPA"
(cd "$TASK_ROOT/dist" && /usr/bin/shasum -a 256 "$(basename "$TASK_IPA")" > "$(basename "$TASK_IPA").sha256")
/usr/bin/python3 scripts/verify-ipa.py "$TASK_IPA"
printf 'Unsigned iPhone IPA: %s\n' "$TASK_IPA"
printf 'Build log: %s/build/release-build.log\n' "$TASK_ROOT"
