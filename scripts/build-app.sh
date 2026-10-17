#!/usr/bin/env bash
# Pawmit.app 번들 만들기: ./scripts/build-app.sh  (CONFIG=debug 로 디버그 빌드, UNIVERSAL=1 로 arm64+x86_64)
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
ARCH_FLAGS=()
if [ "${UNIVERSAL:-0}" = 1 ]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi

swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product Pawmit
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product pawmit-cli
BIN="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

# 앱 아이콘 (없을 때만 렌더링해서 만든다)
if [ ! -f Resources/AppIcon.icns ]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  "$BIN/Pawmit" --render-icon "$ICONSET"
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
fi

APP="build/Pawmit.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Pawmit" "$APP/Contents/MacOS/Pawmit"
cp "$BIN/pawmit-cli" "$APP/Contents/MacOS/pawmit-cli"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"; fi
# 언어 리소스 (en.lproj 등; ko는 원문이라 테이블이 없다)
for LPROJ in Resources/*.lproj; do
  [ -d "$LPROJ" ] && cp -R "$LPROJ" "$APP/Contents/Resources/"
done

# ad-hoc 서명 (로컬 실행용). 배포하려면 Developer ID로 다시 서명·공증해야 한다.
codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/pawmit-cli"
codesign --force --sign - --timestamp=none "$APP"
echo "built: $APP"
