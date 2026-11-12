#!/usr/bin/env bash
# 릴리스 후 homebrew tap(wjchoi87/homebrew-tap)의 pawmit cask를 최신 버전으로 갱신해 push 한다.
# 사용: ./scripts/update-tap.sh [버전]   (버전 생략 시 Resources/Info.plist의 값)
# 순서 주의: GitHub Release(v<버전>)에 Pawmit-<버전>.zip 을 먼저 올리고 실행한다.
#   zip sha256 은 GitHub asset digest 에서 읽어오므로 로컬 빌드 파일이 필요 없다.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="wjchoi87/Pawmit"
TAP_REPO="${TAP_REPO:-wjchoi87/homebrew-tap}"
VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)}"
ZIP_NAME="Pawmit-$VERSION.zip"

# 릴리스·zip asset 확인
gh release view "v$VERSION" --repo "$REPO" >/dev/null
DIGEST="$(gh api "repos/$REPO/releases/tags/v$VERSION" --jq ".assets[] | select(.name == \"$ZIP_NAME\") | .digest")"
if [ -z "$DIGEST" ]; then
  echo "릴리스 v$VERSION 에 $ZIP_NAME 이 없어요. asset 을 먼저 올려 주세요." >&2
  exit 1
fi
SHA256="${DIGEST#sha256:}"

# tap 체크아웃: 기본 ../homebrew-tap, 없으면 임시 clone
TAP_DIR="${TAP_DIR:-$PWD/../homebrew-tap}"
if [ ! -d "$TAP_DIR/.git" ]; then
  TAP_DIR="$(mktemp -d)/homebrew-tap"
  git clone -q "git@github.com:$TAP_REPO.git" "$TAP_DIR"
else
  git -C "$TAP_DIR" pull -q --ff-only
fi

CASK="$TAP_DIR/Casks/pawmit.rb"
sed -i '' -e "s/^  version .*/  version \"$VERSION\"/" -e "s/^  sha256 .*/  sha256 \"$SHA256\"/" "$CASK"
if (cd "$TAP_DIR" && git diff --quiet); then
  echo "cask already at $VERSION"
  exit 0
fi
(cd "$TAP_DIR" && git add Casks/pawmit.rb && git commit -qm "pawmit $VERSION" && git push -q)
echo "tap updated: $TAP_REPO → $VERSION (sha256 $SHA256)"
