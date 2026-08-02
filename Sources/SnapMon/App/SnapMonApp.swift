import AppKit
import SwiftUI
import UserNotifications

@main
struct SnapMonApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var model = AppModel()

  var body: some Scene {
    mainWindowScene

    Settings {
      SettingsView()
        .environment(model)
        .font(AppTypography.body)
    }
  }

  private var mainWindowScene: some Scene {
    WindowGroup("SnapMon") {
      ContentView()
        .environment(model)
        .font(AppTypography.body)
        .frame(minWidth: 860, minHeight: 560)
        .background {
          MainWindowConfigurationView(
            allowsTransparency: model.isInspectorTranslucent
          )
        }
    }
    .defaultSize(width: 1_150, height: 720)
    .commands {
      CommandGroup(replacing: .newItem) {}
    }
  }
}

private enum MainWindowIdentity {
  static let title = "SnapMon"
  static let identifier = NSUserInterfaceItemIdentifier("SnapMon.MainWindow")
}

private struct MainWindowConfigurationView: NSViewRepresentable {
  let allowsTransparency: Bool

  func makeNSView(context: Context) -> MainWindowConfigurationNSView {
    MainWindowConfigurationNSView(
      allowsTransparency: allowsTransparency
    )
  }

  func updateNSView(
    _ nsView: MainWindowConfigurationNSView,
    context: Context
  ) {
    nsView.allowsTransparency = allowsTransparency
  }
}

private final class MainWindowConfigurationNSView: NSView {
  var allowsTransparency: Bool {
    didSet {
      configureWindowIfNeeded()
    }
  }

  init(allowsTransparency: Bool) {
    self.allowsTransparency = allowsTransparency
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    configureWindowIfNeeded()
  }

  private func configureWindowIfNeeded() {
    guard let window else {
      return
    }

    window.identifier = MainWindowIdentity.identifier
    window.isRestorable = false
    window.isOpaque = !allowsTransparency
    window.backgroundColor = allowsTransparency ? .clear : .windowBackgroundColor
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
  private let placementStore = WindowPlacementStore()
  private weak var mainWindow: NSWindow?
  private var didRestoreMainWindow = false
  private var isRestoreScheduled = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    UNUserNotificationCenter.current().delegate = self
    startObservingWindows()

    DispatchQueue.main.async { [weak self] in
      self?.findAndConfigureMainWindow()
    }
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    findAndConfigureMainWindow()
  }

  func applicationShouldTerminateAfterLastWindowClosed(
    _ sender: NSApplication
  ) -> Bool {
    false
  }

  func applicationWillTerminate(_ notification: Notification) {
    if let mainWindow {
      savePlacement(of: mainWindow)
    } else if let window = NSApplication.shared.windows.first(where: isMainWindow) {
      savePlacement(of: window)
    }
    _ = UserDefaults.standard.synchronize()
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
  }

  private func startObservingWindows() {
    let center = NotificationCenter.default
    center.addObserver(
      self,
      selector: #selector(windowDidBecomeMain(_:)),
      name: NSWindow.didBecomeMainNotification,
      object: nil
    )
    center.addObserver(
      self,
      selector: #selector(windowFrameDidChange(_:)),
      name: NSWindow.didMoveNotification,
      object: nil
    )
    center.addObserver(
      self,
      selector: #selector(windowFrameDidChange(_:)),
      name: NSWindow.didResizeNotification,
      object: nil
    )
  }

  @objc private func windowDidBecomeMain(_ notification: Notification) {
    guard let window = notification.object as? NSWindow else {
      return
    }

    configureMainWindow(window)
  }

  @objc private func windowFrameDidChange(_ notification: Notification) {
    guard
      didRestoreMainWindow,
      let window = notification.object as? NSWindow,
      window === mainWindow
    else {
      return
    }

    savePlacement(of: window)
  }

  private func findAndConfigureMainWindow() {
    guard let window = NSApplication.shared.windows.first(where: isMainWindow) else {
      return
    }

    configureMainWindow(window)
  }

  private func configureMainWindow(_ window: NSWindow) {
    guard isMainWindow(window) else {
      return
    }

    window.identifier = MainWindowIdentity.identifier
    window.isRestorable = false

    if mainWindow !== window {
      mainWindow = window
      didRestoreMainWindow = false
      isRestoreScheduled = false
    }

    scheduleRestorationIfNeeded(for: window)
  }

  private func scheduleRestorationIfNeeded(for window: NSWindow) {
    guard !didRestoreMainWindow, !isRestoreScheduled else {
      return
    }

    isRestoreScheduled = true
    DispatchQueue.main.async { [weak self, weak window] in
      guard let self, let window, self.mainWindow === window else {
        return
      }

      self.isRestoreScheduled = false
      if let placement = self.placementStore.load(),
        let restoredFrame = placement.restoredFrame(
          on: NSScreen.screens.map(WindowScreenGeometry.init)
        )
      {
        window.setFrame(restoredFrame, display: false)
      }
      self.didRestoreMainWindow = true
      self.savePlacement(of: window)
    }
  }

  private func savePlacement(of window: NSWindow) {
    guard
      !window.styleMask.contains(.fullScreen),
      let screen = window.screen ?? screen(containing: window.frame)
    else {
      return
    }

    placementStore.save(
      WindowPlacement(
        frame: window.frame,
        screen: WindowScreenGeometry(screen)
      )
    )
  }

  private func isMainWindow(_ window: NSWindow) -> Bool {
    window.identifier == MainWindowIdentity.identifier
      || window.title == MainWindowIdentity.title
  }

  private func screen(containing frame: CGRect) -> NSScreen? {
    NSScreen.screens.max {
      frame.intersectionArea(with: $0.frame) < frame.intersectionArea(with: $1.frame)
    }
  }
}

extension WindowScreenGeometry {
  fileprivate init(_ screen: NSScreen) {
    self.init(name: screen.localizedName, visibleFrame: screen.visibleFrame)
  }
}

extension CGRect {
  fileprivate func intersectionArea(with other: CGRect) -> CGFloat {
    let intersection = intersection(other)
    guard !intersection.isNull else {
      return 0
    }

    return intersection.width * intersection.height
  }
}
