#!/bin/zsh
# テモト.app を公証（notarization）に出す
#
# 使い方:
#   1) 一度だけ: App用パスワードをキーチェーンに覚えさせる（下の「準備」参照）
#   2) 毎回:     scripts/notarize.sh [対象.appパス]
#
# ────────────────────────────────────────────────
# なぜ要るか
# ────────────────────────────────────────────────
# Developer ID 署名だけの .app を配ると、受け取った人の Mac が
# 「悪意のあるソフトウェアがないか確認できないため開けません」と止める。
# Apple の機械審査（公証）を通し、その印を .app に貼る（staple）と、
# 初回だけ「開いてもよいか」の確認で済むようになる。
#
# ────────────────────────────────────────────────
# 準備（一度だけ・作者の操作）
# ────────────────────────────────────────────────
# 1. https://account.apple.com/account/manage → サインイン →
#    「アプリ用パスワード」→ 生成（名前は temoto-notary など）
# 2. ターミナルで:
#      xcrun notarytool store-credentials temoto-notary \
#        --apple-id <Apple IDのメール> --team-id <TEAM_ID>
#    → パスワードを聞かれたら、1で作ったApp用パスワードを貼る
#    （キーチェーンに保存され、以後このスクリプトが使う。
#     ⚠️ パスワードをファイルやチャットに書かないこと）
set -euo pipefail

if [[ -z "${DEVELOPER_DIR:-}" && -d /Library/Developer/CommandLineTools ]]; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi

APP="${1:-$HOME/Applications/Temoto.app}"
PROFILE="${TEMOTO_NOTARY_PROFILE:-temoto-notary}"
WORK="$(/usr/bin/mktemp -d -t temoto-notarize)"
ZIP="$WORK/Temoto.zip"

[[ -d "$APP" ]] || { echo "🔴 見つかりません: $APP" 1>&2; exit 1; }

echo "▼ 署名の確認" 1>&2
/usr/bin/codesign -v --strict "$APP" || { echo "🔴 署名が正しくありません。先に scripts/build-app.sh を通してください" 1>&2; exit 1; }

# ⚠️ ditto で圧縮する（Finderの圧縮やzipコマンドは拡張属性を落とし、公証が失敗することがある）
echo "▼ 圧縮" 1>&2
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

echo "▼ Apple へ提出（数分かかります）" 1>&2
/usr/bin/xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait 1>&2 || {
  echo "🔴 公証に失敗しました。ログ: xcrun notarytool log <ID> --keychain-profile $PROFILE" 1>&2
  echo "   （準備が済んでいない場合は、このスクリプト冒頭の「準備」を先に）" 1>&2
  exit 1
}

echo "▼ 印を貼る（staple）" 1>&2
/usr/bin/xcrun stapler staple "$APP" 1>&2

echo "▼ 受け取った人のMacと同じ目で確認" 1>&2
/usr/bin/spctl --assess --type execute -v "$APP" 1>&2 || {
  echo "🔴 Gatekeeper の確認に通りません" 1>&2; exit 1
}

/bin/rm -rf "$WORK"
echo "" 1>&2
echo "できました: $APP は公証済みです。" 1>&2
echo "配るとき: ditto -c -k --keepParent \"$APP\" Temoto.zip" 1>&2
