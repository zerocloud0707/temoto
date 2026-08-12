#!/bin/bash
# 配る形（DMG）を作る。
#
# 2026-08-06 作者「Developer IDでやります。その際に問題ない形式にお願い。」
#
# ⚠️ ここで作るのは「人に渡して、そのまま開ける」ものです。
# 署名しただけの .app を渡すと、macOS は
#   「"テモト"は、Appleによる悪質なソフトウェアのチェックを受けていないため開けません」
# と言って開かせません。**公証（notarization）まで済ませて初めて渡せる形**になります。
#
# 使い方:
#   scripts/release.sh            … 作って公証まで（App用パスワードの登録が要る）
#   scripts/release.sh --no-notary … 公証を飛ばして DMG だけ作る（手元の確認用）
#
# 事前に一度だけ（作者の手で。パスワードは私に見せない）:
#   xcrun notarytool store-credentials temoto-notary \
#     --apple-id <Apple ID> --team-id <TEAM_ID> --password <App用パスワード>
#   App用パスワードは https://account.apple.com → サインインとセキュリティ →
#   App用パスワード で作る（Apple ID のパスワードそのものではない）
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$HOME/Applications/Temoto.app"
PROFILE="${TEMOTO_NOTARY_PROFILE:-temoto-notary}"
NOTARIZE=1
[ "${1:-}" = "--no-notary" ] && NOTARIZE=0

OUT_DIR="$ROOT/dist"
mkdir -p "$OUT_DIR"

# ── ① .app を作り直す（検証が1件でも落ちれば build-app.sh 側が止める）
echo "▼ アプリを作ります" 1>&2
bash scripts/build-app.sh 1>&2

# ── ② 配布物の中身を点検する。
# ⚠️ ここは「うっかり混ざったもの」を出す前に捕まえる網。
# 実際に 2026-08-06、別案件のコード（請求書検索）が .app に入ったまま配りかけた。
echo "▼ 中身を点検します" 1>&2
BIN="$APP/Contents/MacOS/Temoto"
LEAKS="$(/usr/bin/strings "$BIN" 2>/dev/null | /usr/bin/grep -icE 'invoice|api\.token|127\.0\.0\.1|localhost:[0-9]' || true)"
if [ "$LEAKS" != "0" ]; then
  echo "🔴 配布物に別案件・内部向けの文字列が $LEAKS 件あります。出す前に外してください:" 1>&2
  /usr/bin/strings "$BIN" | /usr/bin/grep -iE 'invoice|api\.token|127\.0\.0\.1|localhost:[0-9]' | /usr/bin/sort -u | /usr/bin/sed 's/^/    /' 1>&2
  exit 1
fi

# ── ③ 署名の中身を確かめる（公証が通る形になっているか）
echo "▼ 署名を確かめます" 1>&2
INFO="$(/usr/bin/codesign -dvv "$APP" 2>&1)"
echo "$INFO" | /usr/bin/grep -q "Authority=Developer ID Application" || {
  echo "🔴 Developer ID で署名されていません（ad-hoc 署名では公証できません）" 1>&2; exit 1; }
echo "$INFO" | /usr/bin/grep -q "flags=.*runtime" || {
  echo "🔴 Hardened Runtime が入っていません（公証の必須条件）" 1>&2; exit 1; }
echo "$INFO" | /usr/bin/grep -q "^Timestamp=" || {
  echo "🔴 時刻印がありません（公証の必須条件）" 1>&2; exit 1; }
echo "  ✓ Developer ID / Hardened Runtime / 時刻印 いずれもあります" 1>&2

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
DMG="$OUT_DIR/Temoto-$VERSION.dmg"
echo "  版: $VERSION（ビルド $BUILD）" 1>&2

# ── ④ DMG を作る。
# ⚠️ zip ではなく DMG にする理由は2つ。
#   1. **DMG そのものに公証の証書を貼れる**（zip には貼れない）。
#      貼っておくと、受け取った人がインターネットに繋がっていなくても検査が通る。
#   2. 「アプリケーションフォルダへドラッグ」を絵で示せる＝入れ方を説明しなくて済む。
echo "▼ DMG を作ります" 1>&2
STAGE="$(/usr/bin/mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
/usr/bin/ditto "$APP" "$STAGE/テモト.app"
/bin/ln -s /Applications "$STAGE/アプリケーション"
/bin/rm -f "$DMG"
/usr/bin/hdiutil create -volname "テモト $VERSION" -srcfolder "$STAGE" \
  -ov -format UDZO -quiet "$DMG"

# ── ⑤ DMG にも署名する（中の .app だけ署名して DMG が野良だと、経路によっては警告が出る）
echo "▼ DMG に署名します" 1>&2
SIGN_IDENTITY="${TEMOTO_SIGN_IDENTITY:-$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null | /usr/bin/grep -o '"Developer ID Application: [^"]*"' | /usr/bin/head -1 | /usr/bin/tr -d '"')}"
/usr/bin/codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG" 1>&2

if [ "$NOTARIZE" = "0" ]; then
  echo "" 1>&2
  echo "⚠️ 公証を飛ばしました（--no-notary）。**この DMG はまだ人に渡せません**。" 1>&2
  echo "   受け取った人の Mac は「開発元を確認できないため開けません」と言います。" 1>&2
  echo "できたもの: $DMG" 1>&2
  exit 0
fi

# ── ⑥ 公証（Apple に送って、悪意が無いか調べてもらう）
echo "▼ 公証に出します（数分かかります）" 1>&2
/usr/bin/xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait 1>&2 || {
  echo "🔴 公証に失敗しました。何が引っかかったかは:" 1>&2
  echo "     xcrun notarytool history --keychain-profile $PROFILE" 1>&2
  echo "     xcrun notarytool log <出てきたID> --keychain-profile $PROFILE" 1>&2
  echo "   資格情報がまだなら、このファイルの冒頭の手順を先に済ませてください。" 1>&2
  exit 1
}

# ── ⑦ 証書を貼る（貼らないと、繋がっていない Mac で検査が通らない）
echo "▼ 証書を貼ります" 1>&2
/usr/bin/xcrun stapler staple "$DMG" 1>&2

# ── ⑧ 受け取る人と同じ検査をする。ここが通って初めて「渡せる形」
echo "▼ 受け取る人と同じ検査をします" 1>&2
/usr/bin/spctl --assess --type open --context context:primary-signature -vv "$DMG" 1>&2 || {
  echo "🔴 DMG が Gatekeeper に弾かれました" 1>&2; exit 1; }
/usr/bin/xcrun stapler validate "$DMG" 1>&2

SIZE="$(/usr/bin/du -h "$DMG" | /usr/bin/cut -f1)"
SHA="$(/usr/bin/shasum -a 256 "$DMG" | /usr/bin/cut -d' ' -f1)"
echo "" 1>&2
echo "✅ 渡せる形になりました" 1>&2
echo "   $DMG（$SIZE）" 1>&2
echo "   SHA-256: $SHA" 1>&2
echo "" 1>&2
echo "   ※ 配布ページに SHA-256 を載せておくと、受け取った人が" 1>&2
echo "     shasum -a 256 <落としたファイル> で同じものか確かめられます。" 1>&2
echo "$DMG"
