---
name: launch-indicator
description: アプリの起動中をメニューバーと画面右上のバナーで表示する macOS 個人ツール launch-indicator の改修・launchd 常駐。NSWorkspace の起動通知、NSStatusItem、NSPanel のバナー、Swift のビルドと setup.sh を扱うときに参照。
---

# `launch-indicator` — アプリの起動中を表示する

実体: `~/projects/launch-indicator/`。もとは `~/.hammerspoon/init.lua` に書いていた Lua スクリプトで、
Hammerspoon をやめるために Swift へ移した(2026-11-02)。やめた理由は、この1機能のためにアプリを
常駐させる大げささと、`init.lua` だけでは何をどう使っているかが分かりにくく管理しづらかったこと。

常駐の作り(Swift の素のバイナリ + launchd、`.accessory`、右上のパネル)は `app-toggle` と同じ。
違いと、このツール固有の話だけをここに書く。

## 構成

| 部品 | 役割 |
|---|---|
| `launch-indicator.swift` | 常駐本体。1ファイルで完結し、引数は取らない |
| `setup.sh` | `swiftc` でビルド → 署名 → plist 生成 → `launchctl bootstrap`。既定はドライラン、`--apply` で実行 |
| `local.launch-indicator.plist.template` | `{{LABEL}}` `{{DAEMON}}` `{{LOG}}` を `setup.sh` が置き換える |

app-toggle の `setup.rb` と違って Ruby を使わないのは、やることがビルドと登録だけで、
TUI も PATH へのリンクも要らないため。

## 署名

`setup.sh` はビルド後、自己署名証明書 `Local Code Signing` と識別子 `local.launch-indicator`(launchd の
ラベルと同じ)で署名し直す。証明書がキーチェーンになければ、リンカのアドホック署名のまま進む。
証明書の素性と理由はワークスペースの `projects-workspace` skill のルール1.4。

- 今の機能は許可を何も使わないので、署名の効き目はまだない。アクセシビリティなどが要る機能を
  足したときに、ビルドし直すたびに許可が外れないよう先に入れておいた(2026-11-02)
- 確認は `codesign -d -r- build/launch-indicator`。`designated => identifier "local.launch-indicator" and
  certificate leaf = H"1ff2c2…"` なら証明書で署名できている。`cdhash` だけならアドホック署名
- `has_identity` で `grep -q` を使わないのは、`pipefail` 下で一致後に `security` 側が SIGPIPE で
  失敗扱いになりうるため。また `"$IDENTITY」"` のように全角の括弧を変数の直後に置くと、
  bash が変数名の一部と解釈して `unbound variable` になるので `${IDENTITY}` と書く

## 起動の監視

`NSWorkspace.shared.notificationCenter` の3つの通知を使う。Hammerspoon の
`hs.application.watcher` の launching / launched も中身はこれ。

| 通知 | 処理 |
|---|---|
| `willLaunchApplicationNotification` | 表示に加え、スピナーを回し始める |
| `didLaunchApplicationNotification` | 表示から外す |
| `didTerminateApplicationNotification` | 起動途中で落ちたアプリは didLaunch が来ないので、ここでも外す(Lua 版には無かった) |

- **app-toggle から起動を頼まれたら、willLaunch を待たずに出す。** `openApplication` から willLaunch までに
  間があることがあり、キーを押してもしばらくバナーが出なかった(2026-11-10)。app-toggle は未起動のアプリを
  開く直前に分散通知 `local.launch-indicator.willStart`(object = bundle ID、userInfo の `name`)を、
  失敗したら `local.launch-indicator.didFail` を送る。pid がまだ無いので `requested`(bundle ID がキー)に入れ、
  willLaunch が来たら同じ bundle ID のものを `launching` へ移す(開始時刻はキーを押した時刻のまま)。
  willLaunch が先に来ていたら二重に出さない。willLaunch が来なければ同じく30秒で外す
- 依頼の時点の名前は app-toggle がファイル名から取った英語名(計算機なら `Calculator`)で、
  willLaunch で macOS の名前に置き換わる。言語ごとの名前を素のバイナリから引く方法は見つからなかった
- **起動中のアプリは pid で持つ。** Lua 版はアプリ名をキーにしていたが、同じアプリを終了直後に
  起動し直したときなどに、別の起動の完了で表示が消えうるため
- 30秒の時間切れは Lua 版と同じ。スピナーのタイマー(0.25秒ごと)が `refresh()` を呼ぶついでに判定する。
  スピナーは起動中のアプリがなくなったら止めるので、何も起動していない間はタイマーも動かない

## 表示

- **メニューバー**: `NSStatusItem` を起動中のアプリがあるときだけ作り、なくなったら `removeStatusItem` で消す
- **バナー**: `NSPanel`(`.borderless` + `.nonactivatingPanel`、`ignoresMouseEvents`)。1行ごとに高さを足す。
  位置・サイズは Lua 版と同じ(幅320、1行22、余白12、角丸10、文字15)。
  配色は黒地だと分かりづらいとのことで Tailwind の teal にした(背景 teal-50 を不透明度0.65で、枠線1px teal-500、文字 teal-800。2026-11-05)
- **起動が終わったら「✓ アプリ名 起動しました」を1秒出してから消す。** 起動しましたの間は `launchedAt` が入っており、
  メニューバーとスピナーの対象からは外す。時間切れと起動途中の終了では出さずにすぐ消す
- **出す画面はマウスのある画面。** Lua 版の `hs.screen.mainScreen()` はフォーカスのあるウィンドウの画面だが、
  `.accessory` の常駐から見た `NSScreen.main` は自分のキーウィンドウ基準で当てにならない。
  app-toggle に合わせてマウス基準にした
- 通知センターを使わない理由は app-toggle の skill を参照(署名済みバンドルと許可が要る、消す時間を決められない)

## 動作確認

- app-toggle との連携: 両方を scratchpad にビルドし、`app-toggle-daemon --config` に
  `{"hotkeys":[{"bundle_id":"com.apple.calculator","key":"ctrl+opt+shift+f19"}]}` を渡して手で起動、
  `osascript -e 'tell application "System Events" to key code 80 using {control down, option down, shift down}'` で押す。
  ログに `起動の依頼:` → `起動開始:` の順で出ればよい。didFail は小さな Swift で
  `DistributedNotificationCenter.default().postNotificationName(..., deliverImmediately: true)` を送って確かめる

- **表示の確認は `screencapture` ではなく、ウィンドウ一覧で行う**(app-toggle で、実際に出ていたパネルが
  `screencapture -x` に写らなかったため)。`CGWindowListCopyWindowInfo` を 20ms ごとに見ながら
  `open -g -a Calculator` で起動すると、バナー(layer=25、320x46、メニューバーの直下)が出て消えるのが分かる
- メニューバーの項目も layer=25 の窓として作られる(ディスプレイごとに1つ)。ただし計算機のように
  数十msで起動し終わるアプリでは、描かれる前に消えるので onscreen=0 のまま。目視するなら起動の遅いアプリで見る
- 2026-11-02 の初回確認は launchd ではなく手で起動した状態で行った。launchd 配下での確認は、
  ユーザーが `./setup.sh --apply` を実行した後にログ(`起動開始:` / `起動完了:` の行)で行う
