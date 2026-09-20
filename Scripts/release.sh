#!/usr/bin/env bash
#
# Cut a TestFlight build.
#
#   ./Scripts/release.sh
#
# The build number is `git rev-list --count HEAD`, not a value in project.yml.
# App Store Connect burns a version/build pair permanently on first upload, and
# hand-bumping a number is exactly the step that gets forgotten until the upload
# fails at the very end. Commit count is monotonic, never collides, and ties the
# build to the history that produced it.
#
# It is passed to xcodebuild rather than written into project.yml, because
# ENABLE_USER_SCRIPT_SANDBOXING is on by design and a build phase rewriting
# Info.plist would have to fight it. The consequence: archiving from Xcode's UI
# uses project.yml's fallback instead. Release through this script.

set -euo pipefail

cd "$(dirname "$0")/.."

# A build number derived from history is a lie if the tree has changes that are
# not in that history — the number would point at a commit that never contained
# what shipped.
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    echo "error: uncommitted changes. The build number comes from the commit count," >&2
    echo "       so it would not identify what you actually shipped." >&2
    git status --short --untracked-files=no >&2
    exit 1
fi

BUILD=$(git rev-list --count HEAD)
TEAM=$(awk '/DEVELOPMENT_TEAM:/ { print $2; exit }' project.yml)
MARKETING=$(awk -F'"' '/MARKETING_VERSION:/ { print $2; exit }' project.yml)
OUT=build

if [[ -z "$TEAM" || -z "$MARKETING" ]]; then
    echo "error: could not read DEVELOPMENT_TEAM or MARKETING_VERSION from project.yml" >&2
    exit 1
fi

echo "==> Morsel $MARKETING ($BUILD), team $TEAM"

rm -rf "$OUT"
mkdir -p "$OUT"

# The team is read from project.yml rather than repeated here, so there is only
# one place signing identity is declared.
cat > "$OUT/exportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>teamID</key>
    <string>$TEAM</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>uploadSymbols</key>
    <true/>
    <key>destination</key>
    <string>export</string>
</dict>
</plist>
PLIST

echo "==> Regenerating the project"
xcodegen generate

echo "==> Archiving"
xcodebuild -project Morsel.xcodeproj -scheme Morsel -configuration Release \
    -destination "generic/platform=iOS" \
    -archivePath "$OUT/Morsel.xcarchive" \
    CURRENT_PROJECT_VERSION="$BUILD" \
    -allowProvisioningUpdates \
    archive

echo "==> Exporting"
xcodebuild -exportArchive \
    -archivePath "$OUT/Morsel.xcarchive" \
    -exportPath "$OUT/export" \
    -exportOptionsPlist "$OUT/exportOptions.plist" \
    -allowProvisioningUpdates

# Checked before uploading rather than after, because the first attempt at this
# by hand produced a development-signed archive that looked fine locally and was
# only rejected once it reached Apple. A Release build signs with whatever
# identity resolves, and without a distribution certificate that is the
# development one.
echo "==> Verifying the export is distribution-signed"
APP="$OUT/unpacked/Payload/Morsel.app"
mkdir -p "$OUT/unpacked"
unzip -q "$OUT/export/Morsel.ipa" -d "$OUT/unpacked"

# Captured first rather than piped into `grep -q`: under `pipefail` a quiet grep
# exits on its first match, the producer takes SIGPIPE, and the pipeline reports
# failure even though the match succeeded.
SIGNING=$(codesign -dv --verbose=2 "$APP" 2>&1)
ENTITLEMENTS=$(codesign -d --entitlements :- "$APP" 2>/dev/null | plutil -p -)

if ! grep -q "Authority=Apple Distribution" <<<"$SIGNING"; then
    echo "error: not signed with an Apple Distribution certificate." >&2
    grep "Authority=" <<<"$SIGNING" >&2
    exit 1
fi

if ! grep -q '"get-task-allow" => false' <<<"$ENTITLEMENTS"; then
    echo "error: get-task-allow is not false — App Store Connect will reject this." >&2
    grep "get-task-allow" <<<"$ENTITLEMENTS" >&2
    exit 1
fi

echo "==> Uploading to App Store Connect"
cp "$OUT/exportOptions.plist" "$OUT/uploadOptions.plist"
plutil -replace destination -string upload "$OUT/uploadOptions.plist"

xcodebuild -exportArchive \
    -archivePath "$OUT/Morsel.xcarchive" \
    -exportPath "$OUT/upload" \
    -exportOptionsPlist "$OUT/uploadOptions.plist" \
    -allowProvisioningUpdates

echo "==> Uploaded $MARKETING ($BUILD). It appears in TestFlight once processing finishes."
