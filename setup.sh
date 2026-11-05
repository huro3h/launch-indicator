#!/bin/bash
# launch-indicator のビルドと LaunchAgent の登録・解除。
#
#   ./setup.sh                     何をするかを表示するだけ(ドライラン)
#   ./setup.sh --apply             ビルドして LaunchAgent に登録する(登録済みなら入れ替える)
#   ./setup.sh --uninstall         解除の内容を表示するだけ
#   ./setup.sh --uninstall --apply LaunchAgent を解除して plist を消す
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
LABEL="local.launch-indicator"
DAEMON="$ROOT/build/launch-indicator"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/launch-indicator.log"
DOMAIN="gui/$(id -u)"
# 署名に使う証明書。キーチェーンになければ、リンカが付けるアドホック署名のままにする
IDENTITY="${CODESIGN_IDENTITY:-Local Code Signing}"

apply=false
uninstall=false
for arg in "$@"; do
  case "$arg" in
    --apply) apply=true ;;
    --uninstall) uninstall=true ;;
    *) echo "不明な引数: $arg" >&2; exit 2 ;;
  esac
done

loaded() { launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; }

if $uninstall; then
  echo "解除: $DOMAIN/$LABEL"
  echo "削除: $PLIST"
  $apply || { echo "(ドライラン。実行するには --apply を付ける)"; exit 0; }
  loaded && launchctl bootout "$DOMAIN/$LABEL"
  rm -f "$PLIST"
  echo "解除しました(ビルド結果 $ROOT/build とログ $LOG は残しています)"
  exit 0
fi

# grep -q は一致した時点で抜け、pipefail で security 側の SIGPIPE が失敗扱いになりうるので使わない
has_identity() { security find-identity -p codesigning | grep -F "\"$IDENTITY\"" >/dev/null; }

echo "ビルド: $ROOT/launch-indicator.swift → $DAEMON"
if has_identity; then
  echo "署名:   証明書「${IDENTITY}」(識別子 $LABEL)"
else
  echo "署名:   証明書「${IDENTITY}」がないため、アドホック署名のまま"
fi
echo "生成:   $PLIST"
echo "登録:   $DOMAIN/$LABEL(ログ: $LOG)"
$apply || { echo "(ドライラン。実行するには --apply を付ける)"; exit 0; }

command -v swiftc >/dev/null || { echo "swiftc が見つかりません。Command Line Tools を入れてください" >&2; exit 1; }
mkdir -p "$ROOT/build"
swiftc -O "$ROOT/launch-indicator.swift" -o "$DAEMON"
# アドホック署名はビルドのたびに別のプログラム扱いになり、アクセシビリティなどの許可が外れる。
# 同じ証明書と識別子で署名し続ければ、ビルドし直しても許可が残る
has_identity && codesign --force -s "$IDENTITY" -i "$LABEL" "$DAEMON"

mkdir -p "$(dirname "$PLIST")"
sed -e "s|{{LABEL}}|$LABEL|" -e "s|{{DAEMON}}|$DAEMON|" -e "s|{{LOG}}|$LOG|g" \
  "$ROOT/local.launch-indicator.plist.template" > "$PLIST"
plutil -lint "$PLIST" >/dev/null

# 登録済みなら一度外してから入れ直す(ビルドし直したバイナリに入れ替えるため)
if loaded; then
  launchctl bootout "$DOMAIN/$LABEL"
  # bootout は外し終わる前に戻ることがあり、すぐ bootstrap すると「5: Input/output error」になる
  for _ in {1..50}; do loaded || break; sleep 0.1; done
fi
launchctl bootstrap "$DOMAIN" "$PLIST"

sleep 1
if launchctl print "$DOMAIN/$LABEL" | grep -q 'state = running'; then
  echo "登録しました(常駐中)"
else
  echo "登録しましたが、常駐していません。ログを確認してください: $LOG" >&2
  exit 1
fi
