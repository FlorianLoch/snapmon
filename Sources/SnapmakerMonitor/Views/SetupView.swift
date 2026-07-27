import SwiftUI

struct SetupView: View {
  @Environment(AppModel.self) private var model
  @State private var manualAddress = ""

  var body: some View {
    VStack(spacing: 24) {
      Image(systemName: "printer.filled.and.paper")
        .font(.system(size: 52))
        .foregroundStyle(.tint)

      VStack(spacing: 8) {
        Text("Find your Snapmaker U1")
          .font(AppTypography.largeTitle.weight(.semibold))

        Text("LAN mode must be enabled and the printer must be on this network.")
          .foregroundStyle(.secondary)
      }

      GroupBox {
        if model.discoveredDevices.isEmpty {
          HStack(spacing: 12) {
            ProgressView()
              .controlSize(.small)
            Text("Searching for U1 printers…")
              .foregroundStyle(.secondary)
            Spacer()
          }
          .frame(height: 56)
        } else {
          VStack(spacing: 0) {
            ForEach(model.discoveredDevices) { device in
              Button {
                model.select(device)
              } label: {
                DeviceRow(device: device)
              }
              .buttonStyle(.plain)

              if device.id != model.discoveredDevices.last?.id {
                Divider()
              }
            }
          }
        }
      } label: {
        Label("Nearby printers", systemImage: "dot.radiowaves.left.and.right")
      }

      HStack {
        TextField("IP address, for example 192.168.1.42", text: $manualAddress)
          .textFieldStyle(.roundedBorder)
          .onSubmit(connectManualAddress)

        Button("Connect") {
          connectManualAddress()
        }
        .disabled(
          manualAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || model.isValidatingAddress
        )
      }

      if model.isValidatingAddress {
        ProgressView("Checking printer…")
          .controlSize(.small)
      }
    }
    .padding(48)
    .frame(maxWidth: 640)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func connectManualAddress() {
    let address = manualAddress
    Task {
      await model.connectManualAddress(address)
    }
  }
}

struct DeviceRow: View {
  let device: DiscoveredDevice

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "printer")
        .font(AppTypography.title2)
        .frame(width: 30)

      VStack(alignment: .leading, spacing: 3) {
        Text(device.name)
          .font(AppTypography.headline)
        Text(device.host)
          .font(AppTypography.caption.monospaced())
          .foregroundStyle(.secondary)
      }

      Spacer()

      if let firmwareVersion = device.firmwareVersion {
        Text(firmwareVersion)
          .font(AppTypography.caption)
          .foregroundStyle(.secondary)
      }

      Image(systemName: "chevron.right")
        .foregroundStyle(.tertiary)
    }
    .contentShape(Rectangle())
    .padding(.vertical, 10)
    .padding(.horizontal, 4)
  }
}
