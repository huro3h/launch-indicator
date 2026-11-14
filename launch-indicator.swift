// launch-indicator
//   アプリの起動が始まってから終わるまでの間、メニューバーに「◐ アプリ名 起動中」を、
//   画面右上(メニューバーの直下)に「◐ アプリ名 起動中です...」のバナーを出す。
//   起動が終わったら、バナーに「✓ アプリ名 起動しました」を1秒出してから消す。
//   起動完了の通知が来なかったアプリは、30秒で表示から外す。
//
//   launch-indicator              常駐する(launchd から起動する用)
//   launch-indicator --settings   バナーの配色を設定するウィンドウを開く(右上にデモを出す)
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

// ---- 配色の設定 ---------------------------------------------------------------
//
// `launch-indicator --settings` の設定ウィンドウで変え、JSON に保存する。設定ウィンドウは別のプロセスなので、
// 保存のたびに分散通知を送り、常駐側は受け取ったら読み直す。ファイルがない・読めないときは標準の配色。

let settingsURL = FileManager.default.homeDirectoryForCurrentUser
  .appendingPathComponent("Library/Application Support/launch-indicator/settings.json")
let settingsChangedNotification = Notification.Name("local.launch-indicator.settingsChanged")

func color(hex: Int) -> NSColor {
  NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
          blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

// 色は Tailwind の色名で選ぶ(https://tailwindcss.com/docs/colors)。濃さは役割ごとに決めてあり、
// 背景は薄い 50、枠線は通常の濃さの 500、文字は読みやすい濃さの 800 を使う。値は v3 の16進数
enum Shade { case background, border, text }

let tailwindColors: [(name: String, shades: (background: Int, border: Int, text: Int))] = [
  ("slate", (0xf8fafc, 0x64748b, 0x1e293b)),
  ("gray", (0xf9fafb, 0x6b7280, 0x1f2937)),
  ("zinc", (0xfafafa, 0x71717a, 0x27272a)),
  ("neutral", (0xfafafa, 0x737373, 0x262626)),
  ("stone", (0xfafaf9, 0x78716c, 0x292524)),
  ("red", (0xfef2f2, 0xef4444, 0x991b1b)),
  ("orange", (0xfff7ed, 0xf97316, 0x9a3412)),
  ("amber", (0xfffbeb, 0xf59e0b, 0x92400e)),
  ("yellow", (0xfefce8, 0xeab308, 0x854d0e)),
  ("lime", (0xf7fee7, 0x84cc16, 0x3f6212)),
  ("green", (0xf0fdf4, 0x22c55e, 0x166534)),
  ("emerald", (0xecfdf5, 0x10b981, 0x065f46)),
  ("teal", (0xf0fdfa, 0x14b8a6, 0x115e59)),
  ("cyan", (0xecfeff, 0x06b6d4, 0x155e75)),
  ("sky", (0xf0f9ff, 0x0ea5e9, 0x075985)),
  ("blue", (0xeff6ff, 0x3b82f6, 0x1e40af)),
  ("indigo", (0xeef2ff, 0x6366f1, 0x3730a3)),
  ("violet", (0xf5f3ff, 0x8b5cf6, 0x5b21b6)),
  ("purple", (0xfaf5ff, 0xa855f7, 0x6b21a8)),
  ("fuchsia", (0xfdf4ff, 0xd946ef, 0x86198f)),
  ("pink", (0xfdf2f8, 0xec4899, 0x9d174d)),
  ("rose", (0xfff1f2, 0xf43f5e, 0x9f1239)),
]
let defaultColorName = "teal"

// 知らない色名なら標準の色にする
func tailwindColor(_ name: String, _ shade: Shade) -> NSColor {
  let shades = (tailwindColors.first { $0.name == name } ?? tailwindColors.first { $0.name == defaultColorName }!).shades
  switch shade {
  case .background: return color(hex: shades.background)
  case .border: return color(hex: shades.border)
  case .text: return color(hex: shades.text)
  }
}

// 標準は背景・枠線・文字とも teal。背景は下の画面を少し透かす
struct Appearance: Codable, Equatable {
  var background = defaultColorName
  var backgroundOpacity = 0.65
  var border = defaultColorName
  var text = defaultColorName

  init() {}

  // 項目が欠けたファイルでも、ある分だけ使う
  init(from decoder: Decoder) throws {
    let defaults = Appearance()
    let c = try decoder.container(keyedBy: CodingKeys.self)
    background = try c.decodeIfPresent(String.self, forKey: .background) ?? defaults.background
    backgroundOpacity = try c.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? defaults.backgroundOpacity
    border = try c.decodeIfPresent(String.self, forKey: .border) ?? defaults.border
    text = try c.decodeIfPresent(String.self, forKey: .text) ?? defaults.text
  }

  static func load() -> Appearance {
    guard let data = try? Data(contentsOf: settingsURL) else { return Appearance() }
    do {
      return try JSONDecoder().decode(Appearance.self, from: data)
    } catch {
      log("設定ファイルを読めません: \(settingsURL.path) \(error)")
      return Appearance()
    }
  }

  func save() {
    do {
      try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(),
                                              withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(self).write(to: settingsURL, options: .atomic)
    } catch {
      log("設定ファイルを書けません: \(settingsURL.path) \(error)")
      return
    }
    DistributedNotificationCenter.default().postNotificationName(
      settingsChangedNotification, object: nil, userInfo: nil, deliverImmediately: true)
  }
}

var appearance = Appearance.load()

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
  box.layer?.borderWidth = 1
  box.layer?.cornerRadius = 10
  panel.contentView = box
  return panel
}()

let bannerLabel: NSTextField = {
  let label = NSTextField(labelWithString: "")
  label.font = .systemFont(ofSize: 15)
  label.maximumNumberOfLines = 0
  label.lineBreakMode = .byTruncatingTail
  bannerPanel.contentView?.addSubview(label)
  return label
}()

func applyAppearance() {
  let opacity = min(max(appearance.backgroundOpacity, 0), 1)
  let layer = bannerPanel.contentView?.layer
  layer?.backgroundColor = tailwindColor(appearance.background, .background).withAlphaComponent(opacity).cgColor
  layer?.borderColor = tailwindColor(appearance.border, .border).cgColor
  bannerLabel.textColor = tailwindColor(appearance.text, .text)
}

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

func watchLaunches() {
  let center = NSWorkspace.shared.notificationCenter

  center.addObserver(forName: NSWorkspace.willLaunchApplicationNotification, object: nil, queue: .main) { note in
    guard let app = runningApp(note) else { return }
    let name = app.localizedName ?? "アプリ"
    log("起動開始: \(name) pid=\(app.processIdentifier)")
    let request = app.bundleIdentifier.flatMap { requested.removeValue(forKey: $0) }
    launching[app.processIdentifier] = Launching(name: name, bundleID: app.bundleIdentifier,
                                               startedAt: request?.startedAt ?? Date())
    refresh()
    startSpinner()
  }

  center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
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
  center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
    guard let app = runningApp(note), let entry = launching[app.processIdentifier] else { return }
    if entry.launchedAt == nil { log("起動中に終了: \(app.localizedName ?? "アプリ") pid=\(app.processIdentifier)") }
    launching[app.processIdentifier] = nil
    refresh()
  }

  // ---- app-toggle からの知らせ ----
  //
  // キーを押してから willLaunch が届くまでに間があることがあるので、app-toggle が起動を頼んだ時点で
  // 分散通知を受けて表示を始める。object は bundle ID、userInfo の name は表示名。
  // 通知の名前は app-toggle の app-toggle-daemon.swift と揃える。

  let distributedCenter = DistributedNotificationCenter.default()

  distributedCenter.addObserver(
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
  distributedCenter.addObserver(
    forName: Notification.Name("local.launch-indicator.didFail"), object: nil, queue: .main
  ) { note in
    guard let bundleID = note.object as? String, let entry = requested.removeValue(forKey: bundleID) else { return }
    log("起動の失敗: \(entry.name) \(bundleID)")
    refresh()
  }

  // 設定ウィンドウで配色が変わったら読み直す。バナーを出している最中でもすぐ変わる
  distributedCenter.addObserver(forName: settingsChangedNotification, object: nil, queue: .main) { _ in
    appearance = Appearance.load()
    applyAppearance()
    log("配色を読み直しました: \(appearance)")
  }
}

// ---- 設定ウィンドウ ------------------------------------------------------------
//
// `launch-indicator --settings` で開く。開いている間は右上にデモのバナーを出し続け、見ながら色を選べる。
// 値は変えるたびに保存する(保存ボタンは置かない)。ウィンドウを閉じたらプロセスも終わる。

final class SettingsController: NSObject, NSWindowDelegate {
  let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
  let backgroundPopup = NSPopUpButton()
  let borderPopup = NSPopUpButton()
  let textPopup = NSPopUpButton()
  let opacitySlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
  let opacityLabel = NSTextField(labelWithString: "")
  var demoTimer: Timer?

  override init() {
    super.init()
    // 色名の横に、その役割で使う濃さの見本を付ける
    for (popup, shade) in [(backgroundPopup, Shade.background), (borderPopup, .border), (textPopup, .text)] {
      for entry in tailwindColors {
        popup.addItem(withTitle: entry.name)
        popup.lastItem?.image = swatch(tailwindColor(entry.name, shade))
      }
      popup.target = self
      popup.action = #selector(changed)
    }
    opacitySlider.target = self
    opacitySlider.action = #selector(changed)
    opacitySlider.isContinuous = true
    opacitySlider.widthAnchor.constraint(equalToConstant: 180).isActive = true
    opacityLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    let grid = NSGridView(views: [
      [NSTextField(labelWithString: "背景の色"), backgroundPopup],
      [NSTextField(labelWithString: "背景の不透明度"), NSStackView(views: [opacitySlider, opacityLabel])],
      [NSTextField(labelWithString: "枠線の色"), borderPopup],
      [NSTextField(labelWithString: "文字の色"), textPopup],
    ])
    grid.rowSpacing = 12
    grid.column(at: 0).xPlacement = .trailing
    grid.rowAlignment = .none
    (0..<grid.numberOfRows).forEach { grid.row(at: $0).yPlacement = .center }

    let note = NSTextField(wrappingLabelWithString:
      "色は Tailwind CSS の色名で選びます(濃さは背景 50・枠線 500・文字 800)。右上にデモを表示しています。変更はすぐに保存され、常駐中の表示にも反映されます。")
    note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    note.textColor = .secondaryLabelColor
    note.preferredMaxLayoutWidth = 320

    let reset = NSButton(title: "標準に戻す", target: self, action: #selector(resetToDefaults))
    let stack = NSStackView(views: [grid, note, reset])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 16
    stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

    window.title = "launch-indicator の設定"
    window.contentView = stack
    window.setContentSize(stack.fittingSize)
    window.delegate = self
    window.isReleasedWhenClosed = false
    updateControls()
  }

  func swatch(_ color: NSColor) -> NSImage {
    NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
      let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
      color.setFill()
      path.fill()
      NSColor.separatorColor.setStroke()  // 50 の薄い色でも形が分かるよう縁取る
      path.stroke()
      return true
    }
  }

  func show() {
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate()
    // 実際の表示と同じく、起動中(スピナーが回る)と起動しましたの2行を出す
    demoTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
      spinnerIndex = (spinnerIndex + 1) % spinnerFrames.count
      updateBanner(["\(spinnerFrames[spinnerIndex]) Safari 起動中です...", "✓ 計算機 起動しました"])
    }
    demoTimer?.fire()
  }

  // 設定ファイルの色名が知らないものなら、表示と同じく標準の色を選んでおく
  func select(_ popup: NSPopUpButton, _ name: String) {
    popup.selectItem(withTitle: tailwindColors.contains { $0.name == name } ? name : defaultColorName)
  }

  func updateControls() {
    select(backgroundPopup, appearance.background)
    select(borderPopup, appearance.border)
    select(textPopup, appearance.text)
    opacitySlider.doubleValue = appearance.backgroundOpacity
    updateOpacityLabel()
  }

  func updateOpacityLabel() {
    opacityLabel.stringValue = "\(Int((opacitySlider.doubleValue * 100).rounded()))%"
  }

  @objc func changed() {
    appearance.background = backgroundPopup.titleOfSelectedItem ?? defaultColorName
    appearance.border = borderPopup.titleOfSelectedItem ?? defaultColorName
    appearance.text = textPopup.titleOfSelectedItem ?? defaultColorName
    appearance.backgroundOpacity = (opacitySlider.doubleValue * 100).rounded() / 100
    updateOpacityLabel()
    applyAppearance()
    appearance.save()
  }

  @objc func resetToDefaults() {
    appearance = Appearance()
    updateControls()
    applyAppearance()
    appearance.save()
  }

  func windowWillClose(_ notification: Notification) {
    NSApp.terminate(nil)
  }
}

// ⌘Q・⌘W を効かせるためのメニュー。素のバイナリにはメニューがないので自分で作る
func makeMainMenu() -> NSMenu {
  let appMenu = NSMenu()
  appMenu.addItem(withTitle: "閉じる", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
  appMenu.addItem(withTitle: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
  let appItem = NSMenuItem()
  appItem.submenu = appMenu
  let menu = NSMenu()
  menu.addItem(appItem)
  return menu
}

// ---- 起動 -------------------------------------------------------------------

let app = NSApplication.shared
applyAppearance()

var settingsController: SettingsController?
if CommandLine.arguments.dropFirst().first == "--settings" {
  // ウィンドウを操作できるよう、ふつうのアプリとして前面に出す
  app.setActivationPolicy(.regular)
  app.mainMenu = makeMainMenu()
  settingsController = SettingsController()
  settingsController?.show()
} else {
  watchLaunches()
  log("開始 pid=\(getpid())")
  // Dock には出さない。.prohibited だとウィンドウ(バナー)を出せないので .accessory にする(app-toggle で確認済み)。
  app.setActivationPolicy(.accessory)
}
app.run()
