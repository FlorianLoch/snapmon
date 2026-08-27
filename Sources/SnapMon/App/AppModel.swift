import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
  private enum DefaultsKey {
    static let selectedPrinter = "selected_printer"
    static let maximumFrameRate = "max_frame_rate"
    static let inspectorTranslucent = "inspector_translucent"
  }

  private let defaults: UserDefaults
  private let discoveryService: BonjourDiscoveryService
  private let notificationService: NotificationService
  private let cameraClientFactory: @MainActor (SavedPrinter) -> any CameraSessionClient

  private var hasStarted = false
  private var discoveryTask: Task<Void, Never>?
  private var monitorTask: Task<Void, Never>?
  private var statusPollingTask: Task<Void, Never>?
  private var metadataTask: Task<Void, Never>?
  private var commandTask: Task<Void, Never>?
  private var cameraStartTask: Task<Void, Never>?
  private var cameraPollingTask: Task<Void, Never>?
  private var cameraKeepaliveTask: Task<Void, Never>?
  private var cameraTransitionTask: Task<Void, Never>?
  private var cameraClient: (any CameraSessionClient)?
  private var terminationObserver: NSObjectProtocol?
  private var reducer = PrinterStateReducer()
  private var completionTracker = CompletionTracker()
  private var metadataFetchTracker = MetadataFetchTracker()
  private var cameraIsVisible = false
  private var commandGeneration = 0
  private var cameraTransitionGeneration = 0

  var selectedPrinter: SavedPrinter?
  var discoveredDevices: [DiscoveredDevice] = []
  var connectionState: ConnectionState = .disconnected
  var snapshot = PrinterSnapshot()
  var isValidatingAddress = false
  var isCommandPending = false
  var lastErrorMessage: String?
  var notificationPermission: NotificationPermission = .unknown
  var maxFrameRate: Double
  var isInspectorTranslucent: Bool
  var cameraImage: NSImage?
  var cameraFrameDate: Date?
  var cameraStatus = "Camera idle"

  init(
    defaults: UserDefaults = .standard,
    discoveryService: BonjourDiscoveryService = BonjourDiscoveryService(),
    notificationService: NotificationService = NotificationService(),
    cameraClientFactory: @escaping @MainActor (SavedPrinter) -> any CameraSessionClient = {
      CameraClient(printer: $0)
    }
  ) {
    self.defaults = defaults
    self.discoveryService = discoveryService
    self.notificationService = notificationService
    self.cameraClientFactory = cameraClientFactory

    if let storedRate = defaults.object(
      forKey: DefaultsKey.maximumFrameRate
    ) as? NSNumber {
      maxFrameRate = CameraPreferences.clamp(storedRate.doubleValue)
    } else {
      maxFrameRate = CameraPreferences.defaultFrameRate
    }

    isInspectorTranslucent = defaults.bool(
      forKey: DefaultsKey.inspectorTranslucent
    )

    if let data = defaults.data(forKey: DefaultsKey.selectedPrinter) {
      selectedPrinter = try? JSONDecoder().decode(SavedPrinter.self, from: data)
    }
  }

  func start() {
    guard !hasStarted else {
      return
    }

    hasStarted = true
    startDiscovery()

    Task {
      await refreshNotificationPermission()
    }

    if let selectedPrinter {
      connect(to: selectedPrinter)
    }

    terminationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.shutdown()
      }
    }
  }

  func select(_ device: DiscoveredDevice) {
    select(device.savedPrinter)
  }

  func select(_ printer: SavedPrinter) {
    cancelCommand()
    selectedPrinter = printer
    persistSelectedPrinter()
    reducer.reset()
    snapshot = reducer.snapshot
    completionTracker = CompletionTracker()
    metadataFetchTracker.reset()
    connect(to: printer)

    Task {
      if notificationPermission == .notDetermined {
        await requestNotificationPermission()
      }
    }
  }

  func connectManualAddress(_ address: String) async {
    guard !isValidatingAddress else {
      return
    }

    isValidatingAddress = true
    defer {
      isValidatingAddress = false
    }

    do {
      let printer = try await MoonrakerClient.probe(host: address)
      select(printer)
    } catch {
      present(error)
    }
  }

  func forgetPrinter() {
    selectedPrinter = nil
    defaults.removeObject(forKey: DefaultsKey.selectedPrinter)
    monitorTask?.cancel()
    statusPollingTask?.cancel()
    metadataTask?.cancel()
    cancelCommand()
    monitorTask = nil
    connectionState = .disconnected
    reducer.reset()
    snapshot = reducer.snapshot
    completionTracker = CompletionTracker()
    stopCameraSession()
  }

  func setMaxFrameRate(_ value: Double) {
    let clampedValue = CameraPreferences.clamp(value)
    guard clampedValue != maxFrameRate else {
      return
    }

    maxFrameRate = clampedValue
    defaults.set(clampedValue, forKey: DefaultsKey.maximumFrameRate)

    if let cameraClient, cameraIsVisible {
      startCameraPolling(with: cameraClient)
    }
  }

  func setInspectorTranslucent(_ translucent: Bool) {
    guard translucent != isInspectorTranslucent else {
      return
    }

    isInspectorTranslucent = translucent
    defaults.set(translucent, forKey: DefaultsKey.inspectorTranslucent)
  }

  func setCameraVisible(_ visible: Bool) {
    guard visible != cameraIsVisible else {
      return
    }

    cameraIsVisible = visible

    if visible {
      transitionCameraSession(startAfterStop: true)
    } else {
      stopCameraSession()
    }
  }

  func togglePause() {
    guard let printer = selectedPrinter,
      connectionState.isConnected,
      !isCommandPending,
      snapshot.state == .printing || snapshot.state == .paused
    else {
      return
    }

    let shouldResume = snapshot.state == .paused
    performCommand(for: printer) {
      let client = MoonrakerClient(printer: printer)

      if shouldResume {
        try await client.resume()
      } else {
        try await client.pause()
      }
    }
  }

  func setLED(on: Bool) {
    guard let printer = selectedPrinter,
      connectionState.isConnected,
      !isCommandPending
    else {
      return
    }

    performCommand(for: printer) {
      let confirmedState = try await MoonrakerClient(printer: printer).setLED(on: on)
      try Task.checkCancellation()
      await self.applyConfirmedLEDState(confirmedState, for: printer)
    }
  }

  func setSpeedModifier(_ percentage: Int) {
    guard let printer = selectedPrinter,
      connectionState.isConnected,
      !isCommandPending,
      snapshot.state.isActive,
      PrinterSpeedModifier.values.contains(percentage)
    else {
      return
    }

    performCommand(for: printer) {
      let confirmedModifier = try await MoonrakerClient(printer: printer)
        .setSpeedModifier(percentage)
      try Task.checkCancellation()
      await self.applyConfirmedSpeedModifier(confirmedModifier, for: printer)
    }
  }

  func requestNotificationPermission() async {
    do {
      _ = try await notificationService.requestPermission()
      await refreshNotificationPermission()
    } catch {
      present(error)
    }
  }

  func refreshNotificationPermission() async {
    notificationPermission = await notificationService.permission()
  }

  func dismissError() {
    lastErrorMessage = nil
  }

  func shutdown() {
    discoveryTask?.cancel()
    monitorTask?.cancel()
    statusPollingTask?.cancel()
    metadataTask?.cancel()
    cancelCommand()
    stopCameraSession()

    if let terminationObserver {
      NotificationCenter.default.removeObserver(terminationObserver)
      self.terminationObserver = nil
    }
  }

  private func startDiscovery() {
    discoveryTask?.cancel()
    discoveryTask = Task { [weak self] in
      guard let self else {
        return
      }

      for await devices in discoveryService.devices() {
        guard !Task.isCancelled else {
          return
        }

        discoveredDevices = devices
        updateSavedAddress(from: devices)
      }
    }
  }

  private func updateSavedAddress(from devices: [DiscoveredDevice]) {
    guard let selectedPrinter,
      let rediscovered = devices.first(
        where: { $0.matches(selectedPrinter) }
      ),
      rediscovered.host != selectedPrinter.host
    else {
      return
    }

    let updated = rediscovered.savedPrinter
    self.selectedPrinter = updated
    persistSelectedPrinter()
    connect(to: updated)
  }

  private func connect(to printer: SavedPrinter) {
    cancelCommand()
    monitorTask?.cancel()
    statusPollingTask?.cancel()
    metadataTask?.cancel()
    metadataTask = nil
    metadataFetchTracker.reset()
    connectionState = .connecting

    if cameraIsVisible {
      transitionCameraSession(startAfterStop: true)
    }

    monitorTask = Task { [weak self] in
      await self?.monitor(printer)
    }
    statusPollingTask = Task { [weak self] in
      await self?.pollStatus(printer)
    }
  }

  private func monitor(_ printer: SavedPrinter) async {
    var retryDelay: TimeInterval = 1

    while !Task.isCancelled, selectedPrinter == printer {
      let client = MoonrakerClient(printer: printer)

      do {
        var receivedStatus = false

        for try await objects in client.statusUpdates() {
          try Task.checkCancellation()
          guard selectedPrinter == printer else {
            return
          }

          receivedStatus = true
          retryDelay = 1
          connectionState = .connected
          handleStatus(objects, from: client, printer: printer)
        }

        if receivedStatus {
          if statusIsStale {
            connectionState = .stale("Connection closed")
          }
        } else {
          throw MonitorError.invalidResponse
        }
      } catch is CancellationError {
        return
      } catch {
        if statusIsStale {
          connectionState = .stale(error.localizedDescription)
        }
      }

      let nanoseconds = UInt64(retryDelay * 1_000_000_000)
      try? await Task.sleep(nanoseconds: nanoseconds)
      retryDelay = min(retryDelay * 2, 30)
    }

    if !Task.isCancelled {
      connectionState = .disconnected
    }
  }

  private func pollStatus(_ printer: SavedPrinter) async {
    let client = MoonrakerClient(printer: printer)

    while !Task.isCancelled, selectedPrinter == printer {
      let startedAt = Date()

      do {
        let objects = try await client.currentStatus()
        try Task.checkCancellation()

        guard selectedPrinter == printer else {
          return
        }

        connectionState = .connected
        handleStatus(objects, from: client, printer: printer)
      } catch is CancellationError {
        return
      } catch {
        if statusIsStale {
          connectionState = .stale(error.localizedDescription)
        }
      }

      let elapsed = Date().timeIntervalSince(startedAt)
      let delay = max(0, MonitorIntervals.printerStatusRefresh - elapsed)

      if delay > 0 {
        try? await Task.sleep(
          nanoseconds: UInt64(delay * 1_000_000_000)
        )
      }
    }
  }

  private func handleStatus(
    _ objects: [String: JSONValue],
    from client: MoonrakerClient,
    printer: SavedPrinter
  ) {
    reducer.apply(objects)
    snapshot = reducer.snapshot

    if metadataFetchTracker.beginIfNeeded(for: snapshot.filename) {
      fetchMetadata(
        filename: snapshot.filename,
        client: client,
        printer: printer
      )
    }

    if let completion = completionTracker.observe(snapshot, printer: printer) {
      Task {
        try? await notificationService.notifyCompletion(completion)
      }
    }
  }

  private func fetchMetadata(
    filename: String,
    client: MoonrakerClient,
    printer: SavedPrinter
  ) {
    metadataTask?.cancel()
    metadataTask = Task { [weak self] in
      do {
        let metadata = try await client.metadata(for: filename)
        guard let self,
          !Task.isCancelled,
          selectedPrinter == printer,
          snapshot.filename == filename
        else {
          return
        }

        reducer.setMetadata(metadata, for: filename)
        snapshot = reducer.snapshot
      } catch {
        guard let self,
          !Task.isCancelled,
          selectedPrinter == printer,
          snapshot.filename == filename
        else {
          return
        }

        metadataFetchTracker.didFail(for: filename)
        reducer.setMetadata(nil, for: filename)
        snapshot = reducer.snapshot
      }
    }
  }

  private func performCommand(
    for printer: SavedPrinter,
    _ operation: @escaping @Sendable () async throws -> Void
  ) {
    commandTask?.cancel()
    commandGeneration += 1
    let generation = commandGeneration
    isCommandPending = true
    commandTask = Task { [weak self] in
      defer {
        if let self, commandGeneration == generation {
          isCommandPending = false
          commandTask = nil
        }
      }

      do {
        try await operation()
        try Task.checkCancellation()
      } catch is CancellationError {
        return
      } catch {
        guard let self,
          commandGeneration == generation,
          selectedPrinter == printer
        else {
          return
        }

        present(error)
      }
    }
  }

  func applyConfirmedLEDState(_ isOn: Bool, for printer: SavedPrinter) {
    guard selectedPrinter == printer, !Task.isCancelled else {
      return
    }

    reducer.setLEDState(isOn)
    snapshot = reducer.snapshot
  }

  func applyConfirmedSpeedModifier(_ percentage: Int, for printer: SavedPrinter) {
    guard selectedPrinter == printer, !Task.isCancelled else {
      return
    }

    reducer.setSpeedModifier(percentage)
    snapshot = reducer.snapshot
  }

  private func cancelCommand() {
    commandGeneration += 1
    commandTask?.cancel()
    commandTask = nil
    isCommandPending = false
  }

  private func startCameraSessionIfPossible() {
    guard cameraIsVisible,
      cameraClient == nil,
      let selectedPrinter
    else {
      return
    }

    let client = cameraClientFactory(selectedPrinter)
    cameraClient = client
    cameraStatus = "Starting camera"

    cameraStartTask?.cancel()
    cameraStartTask = Task { [weak self] in
      var retryDelay: TimeInterval = 1

      while let self,
        !Task.isCancelled,
        cameraIsVisible,
        cameraClient === client
      {
        do {
          try await client.startMonitoring()
          guard !Task.isCancelled,
            cameraIsVisible,
            cameraClient === client
          else {
            return
          }

          cameraStatus = "Waiting for camera"
          startCameraPolling(with: client)
          startCameraKeepalive(with: client)
          return
        } catch is CancellationError {
          return
        } catch {
          cameraStatus = "Camera unavailable · \(error.localizedDescription)"
          try? await Task.sleep(
            nanoseconds: UInt64(retryDelay * 1_000_000_000)
          )
          retryDelay = min(retryDelay * 2, 10)
        }
      }
    }
  }

  private func startCameraKeepalive(with client: any CameraSessionClient) {
    cameraKeepaliveTask?.cancel()
    cameraKeepaliveTask = Task { [weak self] in
      while let self,
        !Task.isCancelled,
        cameraIsVisible,
        cameraClient === client
      {
        try? await Task.sleep(
          nanoseconds: UInt64(
            CameraPreferences.monitorWakeInterval * 1_000_000_000
          )
        )
        guard !Task.isCancelled,
          cameraIsVisible,
          cameraClient === client
        else {
          return
        }

        do {
          try await client.startMonitoring()
        } catch is CancellationError {
          return
        } catch {
          // A disposable wake pulse is retried at the next interval.
        }
      }
    }
  }

  private func startCameraPolling(with client: any CameraSessionClient) {
    cameraPollingTask?.cancel()
    cameraPollingTask = Task { [weak self] in
      var consecutiveFailures = 0
      var recoveryController = CameraRecoveryController()

      while let self,
        !Task.isCancelled,
        cameraIsVisible,
        cameraClient === client
      {
        let startedAt = Date()

        do {
          let frame = try await client.frame()
          try Task.checkCancellation()

          if let image = NSImage(data: frame.data) {
            cameraImage = image
            cameraFrameDate = Date()
            cameraStatus = "Live"
          } else {
            throw MonitorError.invalidResponse
          }

          consecutiveFailures = 0

          let recoveryReason = try await recoveryController.rekickIfNeeded(
            frameIdentity: frame.identity,
            at: Date()
          ) { _ in
            self.cameraStatus = "Waking frozen camera"
            try await client.recoverMonitoring()
          }

          if recoveryReason != nil {
            cameraStatus = "Waiting for fresh camera frame"
          }
        } catch is CancellationError {
          return
        } catch {
          consecutiveFailures += 1
          cameraStatus = cameraImage == nil ? "Waiting for camera" : "Reconnecting camera"

          if consecutiveFailures.isMultiple(of: 3) {
            do {
              try await client.recoverMonitoring()
              recoveryController.didRekick()
            } catch {
              cameraStatus = "Reconnecting camera · \(error.localizedDescription)"
            }
          }
        }

        let frameInterval = CameraPreferences.interval(for: maxFrameRate)
        let elapsed = Date().timeIntervalSince(startedAt)
        let failureBackoff =
          consecutiveFailures == 0
          ? 0
          : min(pow(2, Double(consecutiveFailures - 1)), 5)
        let delay = max(frameInterval - elapsed, failureBackoff)

        if delay > 0 {
          try? await Task.sleep(
            nanoseconds: UInt64(delay * 1_000_000_000)
          )
        }
      }
    }
  }

  private func stopCameraSession() {
    transitionCameraSession(startAfterStop: false)
  }

  private func transitionCameraSession(startAfterStop: Bool) {
    cameraStartTask?.cancel()
    cameraPollingTask?.cancel()
    cameraKeepaliveTask?.cancel()
    cameraStartTask = nil
    cameraPollingTask = nil
    cameraKeepaliveTask = nil

    let client = cameraClient
    cameraClient = nil
    cameraImage = nil
    cameraFrameDate = nil
    cameraStatus = startAfterStop && cameraIsVisible ? "Starting camera" : "Camera idle"

    cameraTransitionGeneration += 1
    let generation = cameraTransitionGeneration
    let previousTransition = cameraTransitionTask
    cameraTransitionTask = Task { [weak self] in
      await previousTransition?.value
      await client?.stopMonitoring()

      guard let self,
        cameraTransitionGeneration == generation
      else {
        return
      }

      cameraTransitionTask = nil
      guard startAfterStop, cameraIsVisible else {
        return
      }

      startCameraSessionIfPossible()
    }
  }

  private func persistSelectedPrinter() {
    guard let selectedPrinter,
      let data = try? JSONEncoder().encode(selectedPrinter)
    else {
      defaults.removeObject(forKey: DefaultsKey.selectedPrinter)
      return
    }

    defaults.set(data, forKey: DefaultsKey.selectedPrinter)
  }

  private func present(_ error: Error) {
    lastErrorMessage = error.localizedDescription
  }

  private var statusIsStale: Bool {
    guard let updatedAt = snapshot.updatedAt else {
      return true
    }

    return Date().timeIntervalSince(updatedAt) > MonitorIntervals.connectionStaleAfter
  }
}
