import Foundation
import UserNotifications

enum NotificationPermission: String, Sendable {
  case unknown
  case notDetermined
  case denied
  case authorized

  var label: String {
    switch self {
    case .unknown:
      return "Unknown"
    case .notDetermined:
      return "Not requested"
    case .denied:
      return "Denied"
    case .authorized:
      return "Enabled"
    }
  }
}

final class NotificationService: @unchecked Sendable {
  private var center: UNUserNotificationCenter {
    UNUserNotificationCenter.current()
  }

  func permission() async -> NotificationPermission {
    let settings = await center.notificationSettings()

    switch settings.authorizationStatus {
    case .notDetermined:
      return .notDetermined
    case .denied:
      return .denied
    case .authorized, .provisional, .ephemeral:
      return .authorized
    @unknown default:
      return .unknown
    }
  }

  func requestPermission() async throws -> Bool {
    try await center.requestAuthorization(options: [.alert, .sound])
  }

  func notifyCompletion(_ event: CompletionEvent) async throws {
    let content = UNMutableNotificationContent()
    content.title = "Print finished"

    if event.job.filename.isEmpty {
      content.body = "\(event.printerName) completed its print."
    } else {
      content.body = "\(event.job.filename) finished on \(event.printerName)."
    }

    content.sound = .default

    let identifier = [
      "print-complete",
      event.job.printerSerial,
      String(event.job.observedStart.timeIntervalSince1970),
    ].joined(separator: "-")
    let request = UNNotificationRequest(
      identifier: identifier,
      content: content,
      trigger: nil
    )

    try await center.add(request)
  }
}
