#!/bin/bash
# Assemble dist/NoteCanvas.app from the release CanvasApp binary and zip it.
# Usage: package-app.sh 1.0.0
set -euo pipefail

VERSION="${1:?usage: package-app.sh <version>}"
if ! printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "version must look like 1.0.0" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/.build/release/CanvasApp"
DIST="$ROOT/dist"
APP="$DIST/NoteCanvas.app"
ICONSET="$DIST/AppIcon.iconset"

test -x "$BIN"

rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ICONSET"

cp "$BIN" "$APP/Contents/MacOS/NoteCanvas"
chmod +x "$APP/Contents/MacOS/NoteCanvas"

EXPORTER="$DIST/export-icon"
swiftc -swift-version 5 -framework AppKit -o "$EXPORTER" \
  "$ROOT/Sources/CanvasApp/AppIcon.swift" \
  "$ROOT/.github/export-icon.swift"
"$EXPORTER" "$DIST/AppIcon.png"

while read -r size name; do
  sips -z "$size" "$size" "$DIST/AppIcon.png" --out "$ICONSET/$name" >/dev/null
done <<'EOF'
16 icon_16x16.png
32 icon_16x16@2x.png
32 icon_32x32.png
64 icon_32x32@2x.png
128 icon_128x128.png
256 icon_128x128@2x.png
256 icon_256x256.png
512 icon_256x256@2x.png
512 icon_512x512.png
1024 icon_512x512@2x.png
EOF

iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET" "$EXPORTER" "$DIST/AppIcon.png"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>NoteCanvas</string>
	<key>CFBundleExecutable</key>
	<string>NoteCanvas</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>com.stevencoutts.NoteCanvas</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>NoteCanvas</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${VERSION}</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
EOF

printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist"

codesign --force --sign - "$APP/Contents/MacOS/NoteCanvas"
codesign --force --sign - "$APP"

ZIP="$DIST/NoteCanvas-${VERSION}.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Wrote $ZIP"
