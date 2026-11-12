#!/bin/bash
set -euo pipefail

APP="LiteEdit"
BUILD=".build/release"
BUNDLE="${APP}.app"

echo "▸ Building ${APP} (release)…"
swift build -c release 2>&1

echo "▸ Packaging ${BUNDLE}…"
rm -rf "${BUNDLE}"
mkdir -p "${BUNDLE}/Contents/MacOS"
mkdir -p "${BUNDLE}/Contents/Resources"

cp "${BUILD}/${APP}" "${BUNDLE}/Contents/MacOS/"

if [ -f "LiteEdit.icns" ]; then
  cp "LiteEdit.icns" "${BUNDLE}/Contents/Resources/AppIcon.icns"
fi

cat > "${BUNDLE}/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>LiteEdit</string>
  <key>CFBundleDisplayName</key>
  <string>LiteEdit</string>
  <key>CFBundleIdentifier</key>
  <string>com.liteedit.app</string>
  <key>CFBundleVersion</key>
  <string>1.0.0</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.0</string>
  <key>CFBundleExecutable</key>
  <string>LiteEdit</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSSupportsAutomaticGraphicsSwitching</key>
  <true/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key>
      <string>Text Document</string>
      <key>CFBundleTypeRole</key>
      <string>Editor</string>
      <key>LSHandlerRank</key>
      <string>Owner</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.plain-text</string>
        <string>public.utf8-plain-text</string>
        <string>public.json</string>
        <string>public.xml</string>
        <string>public.yaml</string>
        <string>public.comma-separated-values-text</string>
        <string>net.daringfireball.markdown</string>
        <string>com.apple.property-list</string>
        <string>com.apple.log</string>
      </array>
      <key>CFBundleTypeExtensions</key>
      <array>
        <string>txt</string>
        <string>text</string>
        <string>md</string>
        <string>markdown</string>
        <string>json</string>
        <string>yaml</string>
        <string>yml</string>
        <string>xml</string>
        <string>toml</string>
        <string>plist</string>
        <string>log</string>
        <string>ini</string>
        <string>cfg</string>
        <string>conf</string>
        <string>config</string>
        <string>env</string>
        <string>properties</string>
        <string>gitignore</string>
        <string>editorconfig</string>
      </array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key>
      <string>Source Code</string>
      <key>CFBundleTypeRole</key>
      <string>Editor</string>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.source-code</string>
        <string>public.script</string>
        <string>public.shell-script</string>
        <string>public.html</string>
        <string>public.css</string>
        <string>public.swift-source</string>
        <string>public.c-source</string>
        <string>public.c-header</string>
        <string>public.c-plus-plus-source</string>
        <string>com.netscape.javascript-source</string>
      </array>
      <key>CFBundleTypeExtensions</key>
      <array>
        <string>swift</string>
        <string>py</string>
        <string>js</string>
        <string>ts</string>
        <string>tsx</string>
        <string>html</string>
        <string>htm</string>
        <string>css</string>
        <string>go</string>
        <string>rs</string>
        <string>c</string>
        <string>h</string>
        <string>cpp</string>
        <string>java</string>
        <string>rb</string>
        <string>sh</string>
        <string>sql</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Version = UTC date/time of the last change: newest uncommitted edit if the tree is dirty,
# otherwise the last commit. Short: YYYY.MM.DD  Build: YYYY.MM.DD.HHMM
STAMP=$(git log -1 --format=%ct 2>/dev/null || date +%s)
while IFS= read -r f; do
  [ -f "$f" ] && m=$(stat -f %m "$f") && [ "$m" -gt "$STAMP" ] && STAMP=$m
done < <(git status --porcelain 2>/dev/null | cut -c4- | sed 's/.* -> //')
SHORT_VERSION=$(TZ=UTC date -r "$STAMP" +%Y.%m.%d)
BUILD_VERSION=$(TZ=UTC date -r "$STAMP" +%Y.%m.%d.%H%M)
plutil -replace CFBundleShortVersionString -string "$SHORT_VERSION" "${BUNDLE}/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_VERSION" "${BUNDLE}/Contents/Info.plist"

echo ""
echo "✓ Built ${BUNDLE} v${BUILD_VERSION} ($(du -sh "${BUNDLE}" | cut -f1) on disk)"
echo "  Run:  open ${BUNDLE}"
echo "  Copy: cp -r ${BUNDLE} /Applications/"
