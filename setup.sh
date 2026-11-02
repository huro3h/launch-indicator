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

echo "ビルド: $ROOT/launch-indicator.swift → $DAEMON"
echo "生成:   $PLIST"
echo "登録:   $DOMAIN/$LABEL(ログ: $LOG)"
$apply || { echo "(ドライラン。実行するには --apply を付ける)"; exit 0; }

command -v swiftc >/dev/null || { echo "swiftc が見つかりません。Command Line Tools を入れてください" >&2; exit 1; }
mkdir -p "$ROOT/build"
swiftc -O "$ROOT/launch-indicator.swift" -o "$DAEMON"

mkdir -p "$(dirname "$PLIST")"
sed -e "s|{{LABEL}}|$LABEL|" -e "s|{{DAEMON}}|$DAEMON|" -e "s|{{LOG}}|$LOG|g" \
  "$ROOT/local.launch-indicator.plist.template" > "$PLIST"
plutil -lint "$PLIST" >/dev/null

# 登録済みなら一度外してから入れ直す(ビルドし直したバイナリに入れ替えるため)
loaded && launchctl bootout "$DOMAIN/$LABEL"
launchctl bootstrap "$DOMAIN" "$PLIST"

sleep 1
if launchctl print "$DOMAIN/$LABEL" | grep -q 'state = running'; then
  echo "登録しました(常駐中)"
else
  echo "登録しましたが、常駐していません。ログを確認してください: $LOG" >&2
  exit 1
fi
