#!/usr/bin/env bash
# Pawmit.app 번들 만들기: ./scripts/build-app.sh  (CONFIG=debug 로 디버그 빌드, UNIVERSAL=1 로 arm64+x86_64)
# 배포: UNIVERSAL=1 SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=<notarytool 프로필> ./scripts/build-app.sh
#   → Developer ID 서명·공증·staple 한 build/Pawmit-<버전>.zip, build/Pawmit-<버전>.dmg 과 SHA-256
#   zip은 앱 자동 업데이트가 내려받는 형식이고, dmg은 사람이 수동 설치/Homebrew용이다.
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

# 서명
# 변경 전 정책: 항상 ad-hoc 서명. 배포 zip도 공증 없이 올려 첫 실행 때 "그래도 열기"가 필요했다.
# 변경 후 정책: SIGN_IDENTITY 를 주면 hardened runtime·보안 타임스탬프·Resources/Pawmit.entitlements 로 Developer ID 서명,
#   NOTARY_PROFILE 까지 주면 공증 → staple → build/Pawmit-<버전>.zip 을 만든다. 둘 다 없으면 예전처럼 ad-hoc.
# 변경 이유: Gatekeeper 경고 없이 설치·자동 업데이트되게 (자동 업데이트는 zip 안의 Pawmit.app 을 그대로 쓴다).
# 영향 범위: 배포 빌드. hardened runtime 에서는 앱 안 NSAppleScript(터미널 탭 이동)에 apple-events entitlement 가 필요하다.
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
if [ -n "$NOTARY_PROFILE" ] && [ -z "$SIGN_IDENTITY" ]; then
  echo "NOTARY_PROFILE 은 SIGN_IDENTITY(Developer ID Application)와 함께 써야 해요" >&2
  exit 1
fi
if [ -z "$SIGN_IDENTITY" ]; then
  # ad-hoc 서명 (로컬 실행용)
  codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/pawmit-cli"
  codesign --force --sign - --timestamp=none "$APP"
  echo "built: $APP"
  exit 0
fi

# 안쪽(CLI)부터 서명한다
codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$APP/Contents/MacOS/pawmit-cli"
codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp --entitlements Resources/Pawmit.entitlements "$APP"
codesign --verify --strict --deep "$APP"
echo "signed: $APP"
if [ -z "$NOTARY_PROFILE" ]; then exit 0; fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
ZIP="build/Pawmit-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
NOTARY_OUT="$(xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)" || true
echo "$NOTARY_OUT"
if ! grep -q "status: Accepted" <<<"$NOTARY_OUT"; then
  echo "공증 실패 (xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE 로 사유 확인)" >&2
  exit 1
fi
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute -vv "$APP"
# staple 한 앱으로 배포 zip 을 다시 만든다
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

# 변경 전 정책: 배포물이 zip 하나뿐이었다. 자동 업데이트는 zip을 쓰지만 사람이 설치하기엔 dmg가 더 낯익다.
# 변경 후 정책: staple 한 앱으로 dmg 도 만들어 공증·staple 한다. zip(자동 업데이트용) + dmg(수동 설치·Homebrew용).
# 변경 이유: 수동 설치 경험 개선과 Homebrew cask 배포. dmg 안의 앱은 이미 staple 돼 있어
#           dmg 자체를 공증하지 않아도 Gatekeeper 는 통과하지만, dmg 까지 공증하면 첫 실행 대화상자가 가장 깔끔하다.
# 영향 범위: NOTARY_PROFILE 을 줄 때만 dmg 가 만들어진다 (ad-hoc/서명만 하는 로컬 빌드는 그대로).
DMG="build/Pawmit-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Pawmit" -srcfolder "$APP" -ov -format UDZO "$DMG" -quiet
DMG_NOTARY_OUT="$(xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)" || true
echo "$DMG_NOTARY_OUT"
if ! grep -q "status: Accepted" <<<"$DMG_NOTARY_OUT"; then
  echo "dmg 공증 실패 (zip 은 정상이니 zip 만 배포해도 동작한다)" >&2
  exit 1
fi
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

shasum -a 256 "$ZIP" "$DMG"
echo "notarized: $ZIP"
echo "notarized: $DMG"
