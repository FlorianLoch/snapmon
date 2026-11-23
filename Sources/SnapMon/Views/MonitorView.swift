import AppKit
import SwiftUI

struct MonitorView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    HSplitView {
      CameraView()
        .frame(minWidth: 560, maxHeight: .infinity)
        .clipped()

      InspectorView()
        .frame(minWidth: 280, idealWidth: 320, maxWidth: 380, maxHeight: .infinity)
        .clipped()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background {
      Group {
        if model.isInspectorTranslucent {
          BehindWindowVisualEffectView()
        } else {
          Color(nsColor: .windowBackgroundColor)
        }
      }
      .ignoresSafeArea()
    }
    .toolbar {
      ToolbarItem {
        SettingsLink {
          Label("Settings", systemImage: "gearshape")
        }
      }
    }
    .onAppear {
      model.setCameraVisible(true)
    }
    .onDisappear {
      model.setCameraVisible(false)
    }
  }
}

private struct CameraView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let isPrinterUnreachable = model.connectionState.isUnreachable

    ZStack {
      Color.black

      if let image = model.cameraImage {
        Image(nsImage: image)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if !isPrinterUnreachable {
        ContentUnavailableView {
          Label("Camera", systemImage: "video.slash")
        } description: {
          Text(model.cameraStatus)
        }
        .foregroundStyle(.white, .secondary)
      }
    }
    .overlay {
      ZStack {
        Color.black.opacity(0.7)
        ContentUnavailableView("Printer unreachable", systemImage: "wifi.exclamationmark")
          .foregroundStyle(.white, .secondary)
      }
      .opacity(isPrinterUnreachable ? 1 : 0)
      .animation(
        reduceMotion ? nil : .easeOut(duration: 0.25),
        value: isPrinterUnreachable
      )
      .accessibilityHidden(!isPrinterUnreachable)
      .allowsHitTesting(false)
    }
    .overlay(alignment: .topLeading) {
      if !isPrinterUnreachable {
        HStack(spacing: 7) {
          Circle()
            .fill(model.cameraStatus == "Live" ? .green : .orange)
            .frame(width: 8, height: 8)
          Text(model.cameraStatus)
          Text("·")
          Text("\(Int(model.maxFrameRate)) FPS max")
        }
        .font(AppTypography.caption)
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.black.opacity(0.55), in: Capsule())
        .padding(14)
      }
    }
    .overlay(alignment: .bottomTrailing) {
      if let frameDate = model.cameraFrameDate {
        Text(frameDate, style: .time)
          .font(AppTypography.caption.monospacedDigit())
          .foregroundStyle(.white.opacity(0.8))
          .padding(12)
      }
    }
  }
}

private struct InspectorView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var selectedSpeedIndex = Double(
    PrinterSpeedModifier.closestIndex(to: PrinterSpeedModifier.defaultValue)
  )
  @State private var isAdjustingSpeed = false
  @State private var editingFan: VentilationFan?
  @State private var selectedFanPercentage = 0.0

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          printerHeader
          dimmedContent {
            VStack(alignment: .leading, spacing: 22) {
              jobSection
              temperatureSection
              ventilationSection
            }
          }
        }
        .padding(22)
      }

      dimmedContent {
        VStack(spacing: 0) {
          Divider()
          controls
            .padding(18)
        }
      }
    }
    .disabled(model.isCommandPending)
    .overlay {
      if model.isCommandPending {
        ProgressView()
          .controlSize(.large)
          .accessibilityLabel("Sending command")
      }
    }
    .animation(.easeInOut(duration: 0.16), value: model.isCommandPending)
  }

  private func dimmedContent<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    let shouldDim = !model.connectionState.isConnected

    return content()
      .saturation(shouldDim ? 0 : 1)
      .opacity(shouldDim && !model.isCommandPending ? 0.6 : 1)
      .animation(
        reduceMotion ? nil : .easeOut(duration: 0.25),
        value: shouldDim
      )
      .opacity(model.isCommandPending ? 0.38 : 1)
  }

  private var printerHeader: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        dimmedContent {
          VStack(alignment: .leading, spacing: 2) {
            Text(model.selectedPrinter?.name ?? "Snapmaker U1")
              .font(AppTypography.title2.weight(.semibold))
            Text(model.selectedPrinter?.host ?? "")
              .font(AppTypography.caption.monospaced())
              .foregroundStyle(.secondary)
          }
        }

        Spacer()
        ConnectionBadge(state: model.connectionState)
      }

      if let version = model.firmwareVersion {
        dimmedContent {
          Text("Firmware \(version)")
            .font(AppTypography.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private var jobSection: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text(model.snapshot.state.displayName)
          .font(AppTypography.headline)
        Spacer()
        Text(model.snapshot.progress, format: .percent.precision(.fractionLength(0)))
          .font(AppTypography.headline.monospacedDigit())
      }

      ProgressView(value: model.snapshot.progress)
        .progressViewStyle(.linear)

      Text(
        model.snapshot.filename.isEmpty
          ? "No active file"
          : model.snapshot.filename
      )
      .font(AppTypography.callout)
      .lineLimit(2)
      .foregroundStyle(
        model.snapshot.filename.isEmpty ? .secondary : .primary
      )

      VStack(spacing: 10) {
        MetadataRow(
          title: "Remaining",
          value: formatDuration(model.snapshot.remaining)
        )
        MetadataRow(
          title: "ETA",
          value: model.snapshot.completionDate?.formatted(
            date: .omitted,
            time: .shortened
          ) ?? "—"
        )
        MetadataRow(
          title: "Elapsed",
          value: formatDuration(model.snapshot.elapsed)
        )
        MetadataRow(
          title: "Layer",
          value: layerDescription
        )
      }

      if !model.snapshot.message.isEmpty {
        Text(model.snapshot.message)
          .font(AppTypography.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var temperatureSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Temperatures")
        .font(AppTypography.headline)

      LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
        ForEach(PrinterSnapshot.extruderNames.indices, id: \.self) { index in
          let name = PrinterSnapshot.extruderNames[index]
          let isActive = model.snapshot.activeExtruder == name
          let reading = model.snapshot.nozzles[name, default: TemperatureReading()]

          VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
              Text("Nozzle \(index + 1)")
                .foregroundStyle(.secondary)
              if isActive {
                Text("Active")
                  .foregroundStyle(Color.accentColor)
              }
            }
            .font(AppTypography.caption)

            Text(temperatureDescription(reading))
              .font(AppTypography.callout.monospacedDigit())
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(8)
          .background(
            isActive ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 8)
          )
          .accessibilityElement(children: .combine)
        }
      }

      MetadataRow(
        title: "Bed",
        value: temperatureDescription(model.snapshot.bed)
      )
      MetadataRow(
        title: "Chamber",
        value: temperatureDescription(model.snapshot.chamber)
      )
    }
  }

  private var ventilationSection: some View {
    let ventilation = model.snapshot.ventilation

    return VStack(alignment: .leading, spacing: 12) {
      Text("Ventilation")
        .font(AppTypography.headline)

      if ventilation.powerDetected == false {
        MetadataRow(title: "Mode", value: "Top Cover disconnected")
      } else {
        MetadataRow(title: "Mode", value: ventilation.mode?.displayName ?? "—")
        ForEach(VentilationFan.allCases, id: \.self) { fan in
          fanRow(fan, ventilation: ventilation)
        }
      }
    }
    .onChange(of: ventilation.mode) { editingFan = nil }
    .onChange(of: ventilation.powerDetected) { editingFan = nil }
    .onChange(of: model.connectionState.isConnected) { editingFan = nil }
    .onChange(of: model.selectedPrinter) { editingFan = nil }
  }

  private func fanRow(_ fan: VentilationFan, ventilation: VentilationReading) -> some View {
    HStack(spacing: 6) {
      Text(fan.title)
        .foregroundStyle(.secondary)
      Spacer(minLength: 0)

      if fan == .recirculation, let rpm = ventilation.recirculationRPM {
        Text("\(rpm.formatted(.number.precision(.fractionLength(0)))) rpm")
          .font(AppTypography.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }

      fanSpeedControl(fan, ventilation: ventilation)
    }
    .font(AppTypography.callout.monospacedDigit())
  }

  @ViewBuilder
  private func fanSpeedControl(_ fan: VentilationFan, ventilation: VentilationReading) -> some View {
    let speed = ventilation.speed(for: fan)
    let value = speed?.formatted(.percent.precision(.fractionLength(0))) ?? "—"

    if model.connectionState.isConnected,
      let range = ventilation.adjustableRange(for: fan),
      let speed
    {
      Button {
        let step = Double(VentilationFan.speedStep)
        let nearest = (speed * 100 / step).rounded() * step
        selectedFanPercentage = min(max(nearest, Double(range.lowerBound)), Double(range.upperBound))
        editingFan = fan
      } label: {
        Text(value)
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .fixedSize()
      .accessibilityLabel("\(fan.title) speed")
      .accessibilityValue(value)
      .modifier(FanSpeedPointer(enabled: !model.isCommandPending))
      .popover(
        isPresented: Binding(
          get: { editingFan == fan },
          set: { if !$0 && editingFan == fan { editingFan = nil } }
        ),
        arrowEdge: .trailing
      ) {
        fanSpeedPopover(fan, range: range, currentPercentage: (speed * 100).rounded())
      }
    } else if fan == .exhaust, ventilation.mode?.isInternal == true {
      Text(value)
        .foregroundStyle(.secondary)
        .help("The exhaust fan stays at 0% during internal circulation to retain chamber heat.")
    } else {
      Text(value)
        .foregroundStyle(.secondary)
    }
  }

  private func fanSpeedPopover(
    _ fan: VentilationFan,
    range: ClosedRange<Int>,
    currentPercentage: Double
  ) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(fan.title)
          .font(AppTypography.headline)
        Spacer()
        Text("\(Int(selectedFanPercentage))%")
          .monospacedDigit()
          .accessibilityHidden(true)
      }

      Slider(
        value: $selectedFanPercentage,
        in: Double(range.lowerBound)...Double(range.upperBound),
        step: Double(VentilationFan.speedStep)
      ) {
        Text("\(fan.title) speed")
      } minimumValueLabel: {
        Text("\(range.lowerBound)%")
      } maximumValueLabel: {
        Text("\(range.upperBound)%")
      }
      .labelsHidden()
      .accessibilityValue("\(Int(selectedFanPercentage)) percent")

      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { editingFan = nil }
          .keyboardShortcut(.cancelAction)
        Button("Apply") {
          editingFan = nil
          model.setFanSpeed(Int(selectedFanPercentage), for: fan)
        }
        .keyboardShortcut(.defaultAction)
        .disabled(selectedFanPercentage == currentPercentage)
      }
    }
    .padding(16)
    .frame(width: 260)
  }

  private var controls: some View {
    VStack(spacing: 12) {
      Toggle(
        isOn: Binding(
          get: { model.snapshot.ledOn },
          set: { model.setLED(on: $0) }
        )
      ) {
        HStack {
          Text("LED strip")
          Spacer()
        }
      }
      .toggleStyle(.switch)
      .frame(maxWidth: .infinity)
      .disabled(!model.connectionState.isConnected || model.isCommandPending)

      speedControl
        .padding(.bottom, 24)

      Button {
        model.togglePause()
      } label: {
        Label(
          model.snapshot.state == .paused ? "Resume print" : "Pause print",
          systemImage: model.snapshot.state == .paused ? "play.fill" : "pause.fill"
        )
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .disabled(
        !model.connectionState.isConnected
          || model.isCommandPending
          || !model.snapshot.state.isActive
      )
    }
  }

  private var speedControl: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("Print speed")
        Spacer()
        Text("\(selectedSpeedModifier)%")
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }

      Slider(
        value: $selectedSpeedIndex,
        in: 0...Double(PrinterSpeedModifier.values.count - 1),
        step: 1
      ) {
        Text("Print speed")
      } onEditingChanged: { isEditing in
        isAdjustingSpeed = isEditing

        if !isEditing, selectedSpeedModifier != model.snapshot.speedModifier {
          model.setSpeedModifier(selectedSpeedModifier)
        }
      }
      .labelsHidden()
      .accessibilityValue("\(selectedSpeedModifier) percent")

      HStack(spacing: 0) {
        ForEach(PrinterSpeedModifier.values, id: \.self) { percentage in
          Text("\(percentage)%")
            .frame(maxWidth: .infinity)
        }
      }
      .font(AppTypography.caption.monospacedDigit())
      .foregroundStyle(.secondary)
    }
    .disabled(
      !model.connectionState.isConnected
        || model.isCommandPending
        || !model.snapshot.state.isActive
    )
    .onAppear {
      synchronizeSpeedSelection(with: model.snapshot.speedModifier)
    }
    .onChange(of: model.snapshot.speedModifier) { _, percentage in
      guard !isAdjustingSpeed else {
        return
      }

      synchronizeSpeedSelection(with: percentage)
    }
  }

  private var selectedSpeedModifier: Int {
    PrinterSpeedModifier.value(at: selectedSpeedIndex)
  }

  private func synchronizeSpeedSelection(with percentage: Int) {
    selectedSpeedIndex = Double(PrinterSpeedModifier.closestIndex(to: percentage))
  }

  private var layerDescription: String {
    switch (model.snapshot.currentLayer, model.snapshot.totalLayers) {
    case (let current?, let total?):
      return "\(current) of \(total)"
    case (let current?, nil):
      return "\(current)"
    default:
      return "—"
    }
  }

  private func temperatureDescription(_ reading: TemperatureReading) -> String {
    guard let current = reading.current else {
      return "—"
    }

    let currentValue = current.formatted(.number.precision(.fractionLength(0)))
    if let target = reading.target, target > 0 {
      let targetValue = target.formatted(.number.precision(.fractionLength(0)))
      return "\(currentValue)° / \(targetValue)°C"
    }

    return "\(currentValue)°C"
  }

  private func formatDuration(_ duration: TimeInterval?) -> String {
    guard let duration, duration.isFinite, duration >= 0 else {
      return "—"
    }

    let seconds = Int(duration.rounded())
    let hours = seconds / 3_600
    let minutes = (seconds % 3_600) / 60
    let remainingSeconds = seconds % 60

    if hours > 0 {
      return "\(hours)h \(minutes)m \(remainingSeconds)s"
    }

    if minutes > 0 {
      return "\(minutes)m \(remainingSeconds)s"
    }

    return "\(remainingSeconds)s"
  }
}

private struct FanSpeedPointer: ViewModifier {
  let enabled: Bool

  func body(content: Content) -> some View {
    if #available(macOS 15, *) {
      content.pointerStyle(enabled ? .link : nil)
    } else {
      content.background {
        if enabled { PointingHandCursor() }
      }
    }
  }
}

private struct PointingHandCursor: NSViewRepresentable {
  func makeNSView(context: Context) -> CursorView { CursorView() }

  func updateNSView(_ nsView: CursorView, context: Context) {}

  final class CursorView: NSView {
    override func resetCursorRects() {
      super.resetCursorRects()
      addCursorRect(visibleRect, cursor: .pointingHand)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }
}

private struct BehindWindowVisualEffectView: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let visualEffectView = NSVisualEffectView()
    visualEffectView.blendingMode = .behindWindow
    visualEffectView.material = .sidebar
    visualEffectView.state = .followsWindowActiveState
    return visualEffectView
  }

  func updateNSView(
    _ nsView: NSVisualEffectView,
    context: Context
  ) {}
}

private struct MetadataRow: View {
  let title: String
  let value: String

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title)
        .foregroundStyle(.secondary)
      Spacer()
      Text(value)
        .monospacedDigit()
        .multilineTextAlignment(.trailing)
    }
    .font(AppTypography.callout)
  }
}

private struct ConnectionBadge: View {
  let state: ConnectionState

  var body: some View {
    HStack(spacing: 5) {
      Circle()
        .fill(color)
        .frame(width: 7, height: 7)
      Text(state.label)
    }
    .font(AppTypography.caption.weight(.medium))
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .background(color.opacity(0.13), in: Capsule())
  }

  private var color: Color {
    switch state {
    case .connected:
      return .green
    case .connecting, .stale:
      return .orange
    case .disconnected:
      return .secondary
    }
  }
}
