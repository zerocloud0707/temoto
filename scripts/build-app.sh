#!/bin/zsh
# テモト.app をビルドする
# 使い方: scripts/build-app.sh [出力先.appパス]
#
# 動作確認（swift run TemotoChecks）を先に通してから組み立てる。
# 検証が落ちたまま .app ができてしまうと、壊れたものを実機に入れることになるため。
#
# ────────────────────────────────────────────────
# 作り直すたびに定型文が消えないようにする仕組み
# ────────────────────────────────────────────────
# ad-hoc署名は作り直すたびに変わり、macOSは前のビルドが作ったキーチェーンの鍵を
# 「他人のもの」と見なす。読もうとすると許可ダイアログが出るが、
# これはキーチェーンのパスワードを求めてきて、作者の環境では答えられなかった。
#
# 実測（2026-07-28）:
#   自分が作った鍵を読む   → 即座に成功・無言
#   別署名が作った鍵を読む → ダイアログ（パスワード要求）で止まる
#   別署名が作った鍵を消す → 成功・無言・パスワード不要
#
# つまり「読めない鍵は捨てて作り直す」ならパスワードは一度も要らない。
# ただし素直にやると定型文とメモが毎回消えるので、
# 古い .app がまだ動くうちに取り出し（export）、作り直した後に書き戻す（import）。
#
# クリップボード履歴は運ばない。パスワードやトークンが入りうるので、
# 一瞬でも平文のファイルに置きたくない。履歴は作り直しのたびに空から始める。
set -euo pipefail

# ビルドの道具はコマンドラインツールに固定する。
# ⚠️ 2026-07-30 に Xcode がインストールされ xcode-select が切り替わり、
# ライセンス未同意のため swift build どころか git や python まで止まった。
# テモトはずっとコマンドラインツールで作ってきたので、ここで固定して再現性を守る。
if [[ -z "${DEVELOPER_DIR:-}" && -d /Library/Developer/CommandLineTools ]]; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi

APP_NAME="Temoto"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# 置き場所は1つだけにする（既定は ~/Applications）。
#
# ⚠️ 2か所に置かないこと（2026-07-28 に実際にやりかけた）。
# 鍵はキーチェーンに1つしか無く、署名（cdhash）と結びついている。
# dist と ~/Applications に別々のビルドが residing すると、
# 後から作った方が鍵を作り直し、もう片方は自分の .enc を読めなくなる。
# 読めない側を起動すると定型文が空に見えて、原因が分からないまま消えたと思う。
OUT_APP="${1:-$HOME/Applications/$APP_NAME.app}"

KEYCHAIN_SERVICE="jp.zerocloud.temoto"
KEYCHAIN_ACCOUNT="store-encryption-key"

cd "$ROOT_DIR"

# 制限時間つきで実行する。
#
# なぜ要るか:
# 引き継ぎに対応していない古い .app に --export-secrets を渡すと、
# 引数を無視してメニューバーアプリとして起動し、返ってこない。
# それをそのまま待つとビルドが永久に止まるので、必ず時間で切る。
# 鍵の許可ダイアログで止まった場合も同じ。
run_limited() {
  local limit=$1; shift
  "$@" &
  local pid=$!
  local waited=0
  while /bin/kill -0 "$pid" 2>/dev/null; do
    if (( waited >= limit )); then
      /bin/kill -TERM "$pid" 2>/dev/null || true
      sleep 1
      /bin/kill -KILL "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid"
}

# 引き継ぎファイルには定型文がそのまま（平文で）入っている。
# 途中で失敗しても必ず消えるように、後片付けを trap に持たせる。
#
# なぜ要るか（2026-07-28 に実際に起きた）:
# codesign が落ちてスクリプトが途中で止まり、
# 取り出し済みの引き継ぎファイルが $TMPDIR に残ったままになった。
# 「消す」処理を成功経路の中にだけ置いていたのが原因。
RELAY_FILE=""
cleanup_relay() {
  if [[ -n "${RELAY_FILE:-}" && -e "${RELAY_FILE:-}" ]]; then
    /bin/rm -f "$RELAY_FILE"
    echo "  引き継ぎファイルを消しました" 1>&2
  fi
  RELAY_FILE=""
}

# ── 同時に2本走らせない ──
#
# なぜ要るか（2026-07-31 に実際に起きた）:
# 1本目が生きているのに死んだと誤認して2本目を起動 → 2本が同じ .app を取り合い、
# 署名が一時的に壊れ、「署名が変わった」と誤認して健在だった暗号鍵を捨てた。
# コピー履歴とメモはこれで失われた。錠は何よりも先に取る。
LOCK_DIR="$HOME/Library/Application Support/$APP_NAME/build.lock"
LOCK_ACQUIRED=""
/bin/mkdir -p "$(dirname "$LOCK_DIR")"
if ! /bin/mkdir "$LOCK_DIR" 2>/dev/null; then
  OTHER_PID="$(/bin/cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  if [[ -n "$OTHER_PID" ]] && /bin/kill -0 "$OTHER_PID" 2>/dev/null; then
    echo "🔴 別のビルド（PID $OTHER_PID）が動いています。終わるのを待ってから実行してください" 1>&2
    exit 1
  fi
  # 持ち主が死んでいる＝前回が異常終了して錠だけ残った。引き取って続ける
  echo "▼ 前回のビルドの錠が残っていました（持ち主は不在）。引き取って続けます" 1>&2
fi
LOCK_ACQUIRED=1
echo $$ > "$LOCK_DIR/pid"

cleanup_all() {
  cleanup_relay
  if [[ -n "${LOCK_ACQUIRED:-}" ]]; then
    /bin/rm -rf "$LOCK_DIR" 2>/dev/null || true
  fi
}
trap cleanup_all EXIT INT TERM

echo "▼ 動作確認" 1>&2
swift run TemotoChecks 1>&2

echo "▼ ビルド（release）" 1>&2
swift build -c release 1>&2

echo "▼ 組み立て" 1>&2
# 起動中のものは先に止める。
# 動いたまま作り直すと、古い方がメニューバーに残って
# 新旧2つがコピー履歴を奪い合い、片方の分が消える。
/usr/bin/pkill -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null && {
  echo "  起動中のものを終了しました" 1>&2
  sleep 1
} || true

# ── 作り直す前に、古い .app で定型文とメモを取り出す ──
# 取り出せるのは「古い .app が自分の鍵を読める」場合だけ。
# 読めなければダイアログが出る前に諦める（終了コード3）。
OLD_REQUIREMENT=""
if [[ -x "$OUT_APP/Contents/MacOS/$APP_NAME" ]]; then
  # 署名の「指定要件」が変わるかどうかを先に見る。変わらないなら鍵はそのまま使えるので何もしない。
  # ⚠️ cdhash だけを見ない。Developer ID 署名の要件は証明書とチームIDで書かれていて
  # ビルドし直しても変わらない＝ここが一致すれば鍵を捨てずに済む（2026-07-30〜の本命経路）。
  OLD_REQUIREMENT="$(/usr/bin/codesign -d -r- "$OUT_APP" 2>/dev/null | /usr/bin/grep '^designated =>' || true)"

  # 古い .app が引き継ぎに対応しているか。
  # 対応していないものに渡すと引数を無視して普通に起動してしまうので、先に確かめる。
  if /usr/bin/grep -q -- "--export-secrets" "$OUT_APP/Contents/MacOS/$APP_NAME" 2>/dev/null; then
    RELAY_FILE="$(/usr/bin/mktemp -t temoto-relay)"
    /bin/chmod 600 "$RELAY_FILE"
    echo "▼ 定型文とメモを取り出し中（古いビルドで）" 1>&2
    set +e
    run_limited 20 "$OUT_APP/Contents/MacOS/$APP_NAME" --export-secrets "$RELAY_FILE" 1>&2
    EXPORT_STATUS=$?
    set -e
    if [[ $EXPORT_STATUS -ne 0 ]]; then
      # 取り出せなくても続ける。作り直したビルドは初期の定型文から始まる。
      # 前の .enc は消さずに .broken として残るので、後から救う余地はある。
      echo "  取り出せませんでした（コード $EXPORT_STATUS）。定型文は初期値から始まります" 1>&2
      /bin/rm -f "$RELAY_FILE"
      RELAY_FILE=""
    fi
  else
    echo "▼ 前の .app は引き継ぎに未対応です（今回は初期値から始まります）" 1>&2
  fi
fi

/bin/rm -rf "$OUT_APP"
/bin/mkdir -p "$OUT_APP/Contents/MacOS" "$OUT_APP/Contents/Resources"
/bin/cp "$ROOT_DIR/resources/Info.plist" "$OUT_APP/Contents/Info.plist"

# ビルド番号は**手で上げない**。コミット数をそのまま使う。
#
# ⚠️ 手で上げる決まりにすると、必ずどこかで上げ忘れる。
# そして macOS は「同じ版なのに中身が違うもの」を見分けられないので、
# 配ったあとに「入れ替えたのに古いままだ」という一番厄介な問い合わせになる。
# コミット数なら、直すたびに必ず1つ増えて、決して戻らない。
BUILD_NUMBER="$(/usr/bin/git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || echo 1)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$OUT_APP/Contents/Info.plist" >/dev/null 2>&1 \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD_NUMBER" "$OUT_APP/Contents/Info.plist" >/dev/null
/bin/cp "$ROOT_DIR/.build/release/$APP_NAME" "$OUT_APP/Contents/MacOS/$APP_NAME"
# アプリアイコン（作り直すときは: .build/debug/Temoto --render-icon <一時フォルダ> → iconutil）
[[ -f "$ROOT_DIR/resources/AppIcon.icns" ]] && /bin/cp "$ROOT_DIR/resources/AppIcon.icns" "$OUT_APP/Contents/Resources/AppIcon.icns"

# 署名の前に拡張属性を全部落とす。
#
# なぜ要るか（2026-07-28 に実際に失敗した）:
# .app に com.apple.FinderInfo が付いていると codesign が
# 「resource fork, Finder information, or similar detritus not allowed」で拒否する。
# set -e で途中終了 → 署名が中途半端なまま残り、書き戻しも後片付けも走らなかった。
# Finder が触ったり iCloud/ファイルプロバイダ経由で置かれると勝手に付くので、毎回落とす。
/usr/bin/xattr -cr "$OUT_APP"

# 署名。Developer ID の証明書があればそれで署名する（2026-07-30 Apple Developer 登録済み）。
#
# Developer ID 署名は作り直しても「同じ持ち主」のままなので、
# キーチェーンの鍵・アクセシビリティ・ファイルの許可・コピー履歴が全部生き残る。
# 証明書が見つからないときだけ ad-hoc に戻る（その場合は昔どおり毎回許可が飛ぶ）。
SIGN_IDENTITY="${TEMOTO_SIGN_IDENTITY:-$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null | /usr/bin/grep -o '"Developer ID Application: [^"]*"' | /usr/bin/head -1 | /usr/bin/tr -d '"' || true)}"
if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "▼ 署名: $SIGN_IDENTITY" 1>&2
  # --timestamp は Apple の時刻印サーバに繋ぐ（証明書の期限後もビルドが有効であり続けるため）。
  # オフラインで失敗したときだけ時刻印なしで妥協する
  /usr/bin/codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$OUT_APP" 1>&2 || /usr/bin/codesign --force --sign "$SIGN_IDENTITY" "$OUT_APP" 1>&2
else
  echo "▼ 署名: 証明書が見つからないため ad-hoc（許可が毎回飛びます）" 1>&2
  /usr/bin/codesign --force --sign - "$OUT_APP" 1>&2
fi

# 署名がちゃんと通っているか、その場で確かめる。
# 壊れた署名のまま「できました」と言うと、実機で起動できずに原因が分からなくなる。
/usr/bin/codesign -v "$OUT_APP" 2>&1 | /usr/bin/sed 's/^/  /' 1>&2 || {
  echo "🔴 署名が正しくありません。中断します" 1>&2
  exit 1
}

NEW_REQUIREMENT="$(/usr/bin/codesign -d -r- "$OUT_APP" 2>/dev/null | /usr/bin/grep '^designated =>' || true)"

# 鍵を守る照合は2段構え。
#
# ① key-owner.txt（アプリが鍵を作ったときに残す持ち主の記録）と、
#    新しい署名のチームIDを直接比べる。旧 .app のバンドルが壊れていても、
#    この記録は壊れない。
#    ⚠️ 2026-07-31 の事故: 旧 .app の署名「だけ」を見ていたため、並走ビルドに
#    バンドルを壊された瞬間の読み取りが空になり、「署名が変わった」と誤認して
#    健在な鍵を捨てた。実際には持ち主（team:<TEAM_ID>）は一致していた。
# ② 記録が無い時代のビルドのために、旧 .app の指定要件の比較も残す。
NEW_TEAM="$(/usr/bin/codesign -dvv "$OUT_APP" 2>&1 | /usr/bin/awk -F= '/^TeamIdentifier=/{print $2}')"
KEY_OWNER="$(/bin/cat "$HOME/Library/Application Support/$APP_NAME/key-owner.txt" 2>/dev/null || true)"
if [[ -n "$NEW_TEAM" && "$NEW_TEAM" != "not set" && "team:$NEW_TEAM" == "$KEY_OWNER" ]]; then
  echo "▼ 鍵の持ち主の記録（$KEY_OWNER）と新しい署名のチームが一致します。鍵はそのまま使えます" 1>&2
  [[ -n "$RELAY_FILE" ]] && /bin/rm -f "$RELAY_FILE"
  RELAY_FILE=""
elif [[ -n "$OLD_REQUIREMENT" && "$OLD_REQUIREMENT" == "$NEW_REQUIREMENT" ]]; then
  # 中身が1バイトも変わらなかった場合。鍵はそのまま読めるので触らない。
  echo "▼ 署名は前と同じです。鍵はそのまま使えます" 1>&2
  [[ -n "$RELAY_FILE" ]] && /bin/rm -f "$RELAY_FILE"
  RELAY_FILE=""
else
  # ── 読めなくなった鍵を捨てる ──
  # 別署名が作った鍵なので、消すのにパスワードは要らない（実測で確認済み）。
  # 消してよい理由: この鍵はテモトが自分で作った乱数で、他のアプリは使っていない。
  # 消した後の .enc は読めなくなるが、アプリ側が .broken に退避して残す（消さない）。
  echo "▼ 署名が変わりました。前の暗号鍵を捨てます" 1>&2
  /usr/bin/security delete-generic-password \
    -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT" >/dev/null 2>&1 \
    && echo "  捨てました" 1>&2 \
    || echo "  ありませんでした（初回か、既に消えています）" 1>&2

  # ── 新しいビルドで書き戻す ──
  if [[ -n "$RELAY_FILE" ]]; then
    echo "▼ 定型文とメモを書き戻し中（新しいビルドで）" 1>&2
    set +e
    run_limited 20 "$OUT_APP/Contents/MacOS/$APP_NAME" --import-secrets "$RELAY_FILE" 1>&2
    IMPORT_STATUS=$?
    set -e
    [[ $IMPORT_STATUS -ne 0 ]] && echo "  書き戻せませんでした（コード $IMPORT_STATUS）" 1>&2
    # 引き継ぎファイルには定型文がそのまま入っているので、必ず消す
    /bin/rm -f "$RELAY_FILE"
  fi
fi

echo "" 1>&2
echo "できました: $OUT_APP" 1>&2
echo "起動: open \"$OUT_APP\"" 1>&2
echo "" 1>&2

echo "$OUT_APP"
