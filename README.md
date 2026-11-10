# launch-indicator

アプリの起動が始まってから終わるまでの間、「起動中」であることを表示する macOS 用の個人ツール。
サードパーティのアプリ(Hammerspoon など)を使わず、Swift の小さな常駐プログラムだけで動く。

- メニューバーに「◐ アプリ名 起動中」(起動中のアプリがあるときだけ出る)
- 画面右上(メニューバーの直下)に「◐ アプリ名 起動中です...」のバナー
- 複数のアプリを同時に起動したときは、まとめて表示する
- 起動完了の通知が来なかったアプリは、30秒で表示から外す
- [app-toggle](https://github.com/huro3h/app-toggle) のショートカットで起動したときは、キーを押した時点で表示を始める
  (macOS の起動の通知を待つと、表示が遅れることがあるため)

アクセシビリティ・入力監視・通知の許可は要らない。

## 要件

| もの | 用途 |
|---|---|
| macOS(動作確認は macOS 15) | |
| Command Line Tools または Xcode(`swiftc`) | 常駐プログラムのビルド |

## セットアップ

```bash
./setup.sh             # 何をするかを表示するだけ(ドライラン)
./setup.sh --apply     # ビルドして LaunchAgent に登録する
```

`setup.sh --apply` は以下を行う。

1. `launch-indicator.swift` を `build/launch-indicator` にコンパイルする
2. キーチェーンにコード署名用の証明書 `Local Code Signing` があれば、それで署名し直す
   (別の証明書を使うなら `CODESIGN_IDENTITY=証明書名 ./setup.sh --apply`。なければアドホック署名のまま)
3. `~/Library/LaunchAgents/local.launch-indicator.plist` をテンプレートから生成する
4. `launchctl` で登録し、常駐を始める(ログイン時にも自動で起動する)

証明書で署名しておくと、ビルドし直しても macOS から同じプログラムとして扱われる。
今は許可の要る機能がないので必須ではないが、将来アクセシビリティなどの許可が要る機能を足したときに、
ビルドのたびに許可を付け直さずに済む。

Swift のソースを変更したときも `./setup.sh --apply` をやり直す(ビルドし直して常駐を入れ替える)。

## 止める・やめる

```bash
./setup.sh --uninstall --apply    # LaunchAgent を解除して plist を消す
```

`build/` とログは残るので、不要なら手で消す。

## 状態の確認

```bash
launchctl print gui/$(id -u)/local.launch-indicator | grep -E 'state|pid'
tail -f ~/Library/Logs/launch-indicator.log    # 起動開始・起動完了が1行ずつ出る
```

## 構成

| ファイル | 役割 |
|---|---|
| `launch-indicator.swift` | 常駐本体。起動の監視、メニューバーとバナーの表示 |
| `setup.sh` | ビルド、LaunchAgent の登録・解除 |
| `local.launch-indicator.plist.template` | LaunchAgent のテンプレート |

実装の詳細・設計判断は `.claude/skills/launch-indicator/SKILL.md` を参照。

## ライセンス

[MIT License](LICENSE)
