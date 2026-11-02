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
| `setup.sh` | `swiftc` でビルド → plist 生成 → `launchctl bootstrap`。既定はドライラン、`--apply` で実行 |
| `local.launch-indicator.plist.template` | `{{LABEL}}` `{{DAEMON}}` `{{LOG}}` を `setup.sh` が置き換える |

app-toggle の `setup.rb` と違って Ruby を使わないのは、やることがビルドと登録だけで、
TUI も PATH へのリンクも要らないため。

## 起動の監視

`NSWorkspace.shared.notificationCenter` の3つの通知を使う。Hammerspoon の
`hs.application.watcher` の launching / launched も中身はこれ。

| 通知 | 処理 |
|---|---|
| `willLaunchApplicationNotification` | 表示に加え、スピナーを回し始める |
| `didLaunchApplicationNotification` | 表示から外す |
| `didTerminateApplicationNotification` | 起動途中で落ちたアプリは didLaunch が来ないので、ここでも外す(Lua 版には無かった) |

- **起動中のアプリは pid で持つ。** Lua 版はアプリ名をキーにしていたが、同じアプリを終了直後に
  起動し直したときなどに、別の起動の完了で表示が消えうるため
- 30秒の時間切れは Lua 版と同じ。スピナーのタイマー(0.25秒ごと)が `refresh()` を呼ぶついでに判定する。
  スピナーは起動中のアプリがなくなったら止めるので、何も起動していない間はタイマーも動かない

## 表示

- **メニューバー**: `NSStatusItem` を起動中のアプリがあるときだけ作り、なくなったら `removeStatusItem` で消す
- **バナー**: `NSPanel`(`.borderless` + `.nonactivatingPanel`、`ignoresMouseEvents`)。1行ごとに高さを足す。
  位置・配色・サイズは Lua 版と同じ(幅320、1行22、余白12、背景 白0.1/透明度0.85、角丸10、文字15)
- **出す画面はマウスのある画面。** Lua 版の `hs.screen.mainScreen()` はフォーカスのあるウィンドウの画面だが、
  `.accessory` の常駐から見た `NSScreen.main` は自分のキーウィンドウ基準で当てにならない。
  app-toggle に合わせてマウス基準にした
- 通知センターを使わない理由は app-toggle の skill を参照(署名済みバンドルと許可が要る、消す時間を決められない)

## 動作確認

- **表示の確認は `screencapture` ではなく、ウィンドウ一覧で行う**(app-toggle で、実際に出ていたパネルが
  `screencapture -x` に写らなかったため)。`CGWindowListCopyWindowInfo` を 20ms ごとに見ながら
  `open -g -a Calculator` で起動すると、バナー(layer=25、320x46、メニューバーの直下)が出て消えるのが分かる
- メニューバーの項目も layer=25 の窓として作られる(ディスプレイごとに1つ)。ただし計算機のように
  数十msで起動し終わるアプリでは、描かれる前に消えるので onscreen=0 のまま。目視するなら起動の遅いアプリで見る
- 2026-11-02 の初回確認は launchd ではなく手で起動した状態で行った。launchd 配下での確認は、
  ユーザーが `./setup.sh --apply` を実行した後にログ(`起動開始:` / `起動完了:` の行)で行う
