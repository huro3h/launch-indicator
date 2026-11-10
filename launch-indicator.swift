// launch-indicator
//   アプリの起動が始まってから終わるまでの間、メニューバーに「◐ アプリ名 起動中」を、
//   画面右上(メニューバーの直下)に「◐ アプリ名 起動中です...」のバナーを出す。
//   起動が終わったら、バナーに「✓ アプリ名 起動しました」を1秒出してから消す。
//   起動完了の通知が来なかったアプリは、30秒で表示から外す。
//
//   launch-indicator   常駐する(launchd から起動する用)
//
//   起動の開始・完了は NSWorkspace の willLaunch / didLaunch 通知で受け取る。
//   app-toggle のホットキーで起動したときは、willLaunch より先に app-toggle から分散通知が届くので、
//   その時点で表示を始める。どれも許可(アクセシビリティ・入力監視・通知)は要らない。

import AppKit

func log(_ message: String) {
  let formatter = DateFormatter()
  formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
  print("\(formatter.string(from: Date())) \(message)")
  fflush(stdout)  // launchd がファイルへ流すので、行ごとに吐く
}

// ---- 起動中のアプリ ----------------------------------------------------------
//
// pid ごとに名前と起動開始時刻を持つ。名前で持たないのは、同じアプリが終了直後に
// もう一度起動されたときなどに、別の起動の完了で表示が消えないようにするため。
// 起動が終わったアプリも「起動しました」を出している間は残し、launchedAt で見分ける。

struct Launching {
  let name: String
  let bundleID: String?
  let startedAt: Date
  var launchedAt: Date?
}

var launching: [pid_t: Launching] = [:]
// app-toggle から起動を頼んだと知らされ、まだ willLaunch が来ていないアプリ。pid がまだ無いので
// bundle ID で持ち、willLaunch が来たら launching へ移す(起動開始時刻はキーを押した時刻のまま)。
var requested: [String: Launching] = [:]
let launchTimeout: TimeInterval = 30
let launchedDisplayTime: TimeInterval = 1  // 「起動しました」を出しておく時間

// ---- スピナー ---------------------------------------------------------------

let spinnerFrames = ["◐", "◓", "◑", "◒"]
var spinnerIndex = 0
var spinnerTimer: Timer?

func startSpinner() {
  guard spinnerTimer == nil else { return }
  spinnerTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
    spinnerIndex = (spinnerIndex + 1) % spinnerFrames.count
    refresh()
  }
}

func stopSpinner() {
  spinnerTimer?.invalidate()
  spinnerTimer = nil
}

// ---- メニューバー -------------------------------------------------------------
//
// 起動中のアプリがあるときだけ項目を作り、なくなったら消す。常にアイコンを置いておくと、
// 何も起動していない間もメニューバーの幅を取るため。

var statusItem: NSStatusItem?

func updateStatusItem(_ names: [String]) {
  if names.isEmpty {
    if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
    statusItem = nil
    return
  }
  if statusItem == nil {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  }
  statusItem?.button?.title = "\(spinnerFrames[spinnerIndex]) \(names.joined(separator: ", ")) 起動中"
}

// ---- バナー ----------------------------------------------------------------
//
// app-toggle の切り替わり表示と同じ作り。通知センターは使わない(署名済みのアプリバンドルと
// 通知の許可が要り、launchd から起動する素のバイナリでは使えないうえ、消すタイミングを
// こちらで決められない)。パネルは前面を奪わず、クリックも素通しする。

let bannerWidth: CGFloat = 320
let bannerLineHeight: CGFloat = 22
let bannerPadding: CGFloat = 12
let bannerMargin: CGFloat = 12

// 配色は Tailwind の teal。薄い背景(50)に通常の濃さの枠線(500)、文字は読みやすい濃さ(800)
func rgb(_ hex: Int) -> NSColor {
  NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
          blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}
let bannerBackground = rgb(0xf0fdfa)  // teal-50
let bannerBorder = rgb(0x14b8a6)      // teal-500
let bannerText = rgb(0x115e59)        // teal-800

let bannerPanel: NSPanel = {
  let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: bannerWidth, height: 100),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
  panel.level = .statusBar
  panel.isOpaque = false
  panel.backgroundColor = .clear
  panel.hasShadow = true
  panel.ignoresMouseEvents = true
  panel.hidesOnDeactivate = false
  // どの操作スペースでも、フルスクリーンのアプリの上でも出す
  panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

  let box = NSView(frame: panel.contentView!.bounds)
  box.autoresizingMask = [.width, .height]
  box.wantsLayer = true
  box.layer?.backgroundColor = bannerBackground.withAlphaComponent(0.65).cgColor  // 下の画面を少し透かす
  box.layer?.borderColor = bannerBorder.cgColor
  box.layer?.borderWidth = 1
  box.layer?.cornerRadius = 10
  panel.contentView = box
  return panel
}()

let bannerLabel: NSTextField = {
  let label = NSTextField(labelWithString: "")
  label.font = .systemFont(ofSize: 15)
  label.textColor = bannerText
  label.maximumNumberOfLines = 0
  label.lineBreakMode = .byTruncatingTail
  bannerPanel.contentView?.addSubview(label)
  return label
}()

func updateBanner(_ lines: [String]) {
  if lines.isEmpty {
    bannerPanel.orderOut(nil)
    return
  }

  bannerLabel.stringValue = lines.joined(separator: "\n")

  let height = bannerPadding * 2 + bannerLineHeight * CGFloat(lines.count)
  bannerLabel.frame = NSRect(x: bannerPadding, y: bannerPadding,
                             width: bannerWidth - bannerPadding * 2, height: height - bannerPadding * 2)

  // マウスのある画面に出す。作業中の画面である可能性がいちばん高いため(app-toggle と同じ)。
  // 画面は表示のたびに選び直すので、起動中にマウスを別の画面へ動かすとバナーも移る。
  let mouse = NSEvent.mouseLocation
  let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
  if let visible = screen?.visibleFrame {  // メニューバーと Dock を除いた領域
    bannerPanel.setFrame(NSRect(x: visible.maxX - bannerWidth - bannerMargin,
                                y: visible.maxY - height - bannerMargin,
                                width: bannerWidth, height: height), display: true)
  }
  bannerPanel.orderFrontRegardless()
}

// ---- 表示の更新 --------------------------------------------------------------

func refresh() {
  let now = Date()
  // 起動完了の通知が来なかった場合に備え、一定時間で表示から外す
  for (pid, entry) in launching
  where entry.launchedAt == nil && now.timeIntervalSince(entry.startedAt) > launchTimeout {
    log("時間切れ: \(entry.name) pid=\(pid)")
    launching[pid] = nil
  }
  for (bundleID, entry) in requested where now.timeIntervalSince(entry.startedAt) > launchTimeout {
    log("時間切れ: \(entry.name) \(bundleID)(起動が始まらなかった)")
    requested[bundleID] = nil
  }

  let entries = (Array(launching.values) + requested.values).sorted { $0.name < $1.name }
  let names = entries.filter { $0.launchedAt == nil }.map(\.name)
  updateStatusItem(names)
  updateBanner(entries.map {
    $0.launchedAt == nil ? "\(spinnerFrames[spinnerIndex]) \($0.name) 起動中です..." : "✓ \($0.name) 起動しました"
  })
  if names.isEmpty { stopSpinner() }
}

// ---- 起動の監視 --------------------------------------------------------------

func runningApp(_ note: Notification) -> NSRunningApplication? {
  note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
}

let center = NSWorkspace.shared.notificationCenter

let willLaunchObserver = center.addObserver(
  forName: NSWorkspace.willLaunchApplicationNotification, object: nil, queue: .main
) { note in
  guard let app = runningApp(note) else { return }
  let name = app.localizedName ?? "アプリ"
  log("起動開始: \(name) pid=\(app.processIdentifier)")
  let request = app.bundleIdentifier.flatMap { requested.removeValue(forKey: $0) }
  launching[app.processIdentifier] = Launching(name: name, bundleID: app.bundleIdentifier,
                                             startedAt: request?.startedAt ?? Date())
  refresh()
  startSpinner()
}

let didLaunchObserver = center.addObserver(
  forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
) { note in
  guard let app = runningApp(note) else { return }
  let pid = app.processIdentifier
  log("起動完了: \(app.localizedName ?? "アプリ") pid=\(pid)")
  guard launching[pid] != nil else { return }
  // すぐには消さず、「起動しました」を少しの間出す
  let launchedAt = Date()
  launching[pid]?.launchedAt = launchedAt
  refresh()
  DispatchQueue.main.asyncAfter(deadline: .now() + launchedDisplayTime) {
    // その間に同じ pid で起動し直されていたら、新しい方の表示は消さない
    guard launching[pid]?.launchedAt == launchedAt else { return }
    launching[pid] = nil
    refresh()
  }
}

// 起動途中で落ちたアプリは didLaunch が来ないので、終了でも表示から外す
let didTerminateObserver = center.addObserver(
  forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
) { note in
  guard let app = runningApp(note), let entry = launching[app.processIdentifier] else { return }
  if entry.launchedAt == nil { log("起動中に終了: \(app.localizedName ?? "アプリ") pid=\(app.processIdentifier)") }
  launching[app.processIdentifier] = nil
  refresh()
}

// ---- app-toggle からの知らせ ---------------------------------------------------
//
// キーを押してから willLaunch が届くまでに間があることがあるので、app-toggle が起動を頼んだ時点で
// 分散通知を受けて表示を始める。object は bundle ID、userInfo の name は表示名。
// 通知の名前は app-toggle の app-toggle-daemon.swift と揃える。

let distributedCenter = DistributedNotificationCenter.default()

let willStartObserver = distributedCenter.addObserver(
  forName: Notification.Name("local.launch-indicator.willStart"), object: nil, queue: .main
) { note in
  guard let bundleID = note.object as? String else { return }
  // 知らせが遅れて willLaunch の後に届いたときは、二重に出さない
  guard !launching.values.contains(where: { $0.launchedAt == nil && $0.bundleID == bundleID }) else { return }
  let name = (note.userInfo?["name"] as? String) ?? bundleID
  log("起動の依頼: \(name) \(bundleID)")
  requested[bundleID] = Launching(name: name, bundleID: bundleID, startedAt: Date())
  refresh()
  startSpinner()
}

// 起動を頼んだが失敗したときは、時間切れを待たずに外す
let didFailObserver = distributedCenter.addObserver(
  forName: Notification.Name("local.launch-indicator.didFail"), object: nil, queue: .main
) { note in
  guard let bundleID = note.object as? String, let entry = requested.removeValue(forKey: bundleID) else { return }
  log("起動の失敗: \(entry.name) \(bundleID)")
  refresh()
}

log("開始 pid=\(getpid())")

let app = NSApplication.shared
// Dock には出さない。.prohibited だとウィンドウ(バナー)を出せないので .accessory にする(app-toggle で確認済み)。
app.setActivationPolicy(.accessory)
app.run()
