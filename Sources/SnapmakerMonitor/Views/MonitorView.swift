import AppKit
import SwiftUI

struct MonitorView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    HSplitView {
      CameraView()
        .frame(minWidth: 560)

      InspectorView()
        .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
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

  var body: some View {
    ZStack {
      Color.black

      if let image = model.cameraImage {
        Image(nsImage: image)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ContentUnavailableView {
          Label("Camera", systemImage: "video.slash")
        } description: {
          Text(model.cameraStatus)
        }
        .foregroundStyle(.white, .secondary)
      }
    }
    .overlay(alignment: .topLeading) {
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

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          printerHeader
          jobSection
          temperatureSection
        }
        .padding(22)
      }

      Divider()
      controls
        .padding(18)
    }
    .background {
      if model.isInspectorTranslucent {
        BehindWindowVisualEffectView()
      } else {
        Color(nsColor: .windowBackgroundColor)
      }
    }
    .opacity(model.isCommandPending ? 0.38 : 1)
    .disabled(model.isCommandPending)
    .overlay {
      if model.isCommandPending {
        ProgressView()
          .controlSize(.large)
          .accessibilityLabel("Sending command")
      }
    }
    .animation(.easeInOut(duration: 0.16), value: model.isCommandPending)
    .animation(.easeInOut(duration: 0.2), value: model.isInspectorTranslucent)
  }

  private var printerHeader: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(model.selectedPrinter?.name ?? "Snapmaker U1")
            .font(AppTypography.title2.weight(.semibold))
          Text(model.selectedPrinter?.host ?? "")
            .font(AppTypography.caption.monospaced())
            .foregroundStyle(.secondary)
        }

        Spacer()
        ConnectionBadge(state: model.connectionState)
      }

      if let version = model.selectedPrinter?.firmwareVersion {
        Text("Firmware \(version)")
          .font(AppTypography.caption)
          .foregroundStyle(.secondary)
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

      MetadataRow(
        title: "Nozzle",
        value: temperatureDescription(model.snapshot.nozzle)
      )
      MetadataRow(
        title: "Bed",
        value: temperatureDescription(model.snapshot.bed)
      )
    }
  }

  private var controls: some View {
    VStack(spacing: 12) {
      Toggle(
        "LED strip",
        isOn: Binding(
          get: { model.snapshot.ledOn },
          set: { model.setLED(on: $0) }
        )
      )
      .toggleStyle(.switch)
      .disabled(!model.connectionState.isConnected || model.isCommandPending)

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

    if let target = reading.target, target > 0 {
      return "\(Int(current.rounded()))° / \(Int(target.rounded()))°C"
    }

    return "\(Int(current.rounded()))°C"
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
