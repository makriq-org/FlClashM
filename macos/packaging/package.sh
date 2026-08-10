#!/bin/sh
set -eu

app=${1:?app bundle path required}
dist=${2:?output directory required}
target=${3:?target name required}
identity=app.flclashm.client

[ -d "$app" ]
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
[ "$bundle_id" = "$identity" ]
arch=$(uname -m)
runtime="$app/Contents/runtimes/macos/$arch"
for binary in mihomo naiveproxy olcrtc byedpi stormdns "$identity.helper"; do
  [ -x "$runtime/$binary" ] || { echo "Missing executable runtime: $binary" >&2; exit 1; }
done
[ -x "$app/Contents/Resources/updater-handoff" ]

mkdir -p "$dist"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$dist/FlClashM-$target.zip"

stage=$(mktemp -d "${TMPDIR:-/tmp}/flclashm-dmg.XXXXXX")
trap '/bin/rm -rf "$stage"' EXIT HUP INT TERM
/usr/bin/ditto "$app" "$stage/FlClashM.app"
/bin/ln -s /Applications "$stage/Applications"
/usr/bin/hdiutil create -quiet -fs HFS+ -format UDZO -volname FlClashM \
  -srcfolder "$stage" "$dist/FlClashM-$target.dmg"
