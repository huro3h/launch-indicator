// launch-indicator
//   アプリの起動が始まってから終わるまでの間、メニューバーに「◐ アプリ名 起動中」を、
//   画面右上(メニューバーの直下)に「◐ アプリ名 起動中です...」のバナーを出す。
//   起動完了の通知が来なかったアプリは、30秒で表示から外す。
//
//   launch-indicator   常駐する(launchd から起動する用)
//
//   起動の開始・完了は NSWorkspace の willLaunch / didLaunch 通知で受け取る。
//   どちらも許可(アクセシビリティ・入力監視・通知)は要らない。

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

struct Launching {
  let name: String
  let startedAt: Date
}

var launching: [pid_t: Launching] = [:]
let launchTimeout: TimeInterval = 30

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
  box.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.85).cgColor
  box.layer?.cornerRadius = 10
  panel.contentView = box
  return panel
}()

let bannerLabel: NSTextField = {
  let label = NSTextField(labelWithString: "")
  label.font = .systemFont(ofSize: 15)
  label.textColor = .white
  label.maximumNumberOfLines = 0
  label.lineBreakMode = .byTruncatingTail
  bannerPanel.contentView?.addSubview(label)
  return label
}()

func updateBanner(_ names: [String]) {
  if names.isEmpty {
    bannerPanel.orderOut(nil)
    return
  }

  bannerLabel.stringValue = names.map { "\(spinnerFrames[spinnerIndex]) \($0) 起動中です..." }
    .joined(separator: "\n")

  let height = bannerPadding * 2 + bannerLineHeight * CGFloat(names.count)
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
  for (pid, entry) in launching where now.timeIntervalSince(entry.startedAt) > launchTimeout {
    log("時間切れ: \(entry.name) pid=\(pid)")
    launching[pid] = nil
  }

  let names = launching.values.map(\.name).sorted()
  updateStatusItem(names)
  updateBanner(names)
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
  launching[app.processIdentifier] = Launching(name: name, startedAt: Date())
  refresh()
  startSpinner()
}

let didLaunchObserver = center.addObserver(
  forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
) { note in
  guard let app = runningApp(note) else { return }
  log("起動完了: \(app.localizedName ?? "アプリ") pid=\(app.processIdentifier)")
  launching[app.processIdentifier] = nil
  refresh()
}

// 起動途中で落ちたアプリは didLaunch が来ないので、終了でも表示から外す
let didTerminateObserver = center.addObserver(
  forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
) { note in
  guard let app = runningApp(note), launching[app.processIdentifier] != nil else { return }
  log("起動中に終了: \(app.localizedName ?? "アプリ") pid=\(app.processIdentifier)")
  launching[app.processIdentifier] = nil
  refresh()
}

log("開始 pid=\(getpid())")

let app = NSApplication.shared
// Dock には出さない。.prohibited だとウィンドウ(バナー)を出せないので .accessory にする(app-toggle で確認済み)。
app.setActivationPolicy(.accessory)
app.run()
