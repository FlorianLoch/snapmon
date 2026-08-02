import AppKit
import SwiftUI

struct SettingsView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.scenePhase) private var scenePhase
  @State private var manualAddress = ""
  @State private var selectedTab = SettingsTab.printer

  var body: some View {
    TabView(selection: $selectedTab) {
      printerSettings
        .tabItem {
          Label("Printer", systemImage: "printer")
        }
        .tag(SettingsTab.printer)

      cameraSettings
        .tabItem {
          Label("Camera", systemImage: "video")
        }
        .tag(SettingsTab.camera)

      appearanceSettings
        .tabItem {
          Label("Appearance", systemImage: "paintbrush")
        }
        .tag(SettingsTab.appearance)

      notificationSettings
        .tabItem {
          Label("Notifications", systemImage: "bell")
        }
        .tag(SettingsTab.notifications)
    }
    .padding(20)
    .frame(width: 560, height: 430)
    .task {
      model.start()
      await model.refreshNotificationPermission()
    }
    .task(id: selectedTab) {
      guard selectedTab == .notifications else {
        return
      }

      await model.refreshNotificationPermission()
    }
    .onChange(of: scenePhase) {
      guard scenePhase == .active else {
        return
      }

      Task {
        await model.refreshNotificationPermission()
      }
    }
  }

  private var printerSettings: some View {
    Form {
      Section("Selected printer") {
        if let printer = model.selectedPrinter {
          LabeledContent("Name", value: printer.name)
          LabeledContent("IP address", value: printer.host)
          LabeledContent("Serial number", value: printer.serialNumber)

          Button("Forget printer", role: .destructive) {
            model.forgetPrinter()
          }
        } else {
          Text("No printer selected")
            .foregroundStyle(.secondary)
        }
      }

      Section("Nearby U1 printers") {
        if model.discoveredDevices.isEmpty {
          HStack {
            ProgressView()
              .controlSize(.small)
            Text("Searching…")
              .foregroundStyle(.secondary)
          }
        } else {
          ForEach(model.discoveredDevices) { device in
            Button {
              model.select(device)
            } label: {
              HStack {
                VStack(alignment: .leading) {
                  Text(device.name)
                  Text(device.host)
                    .font(AppTypography.caption.monospaced())
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if device.id == model.selectedPrinter?.serialNumber {
                  Image(systemName: "checkmark")
                }
              }
            }
            .buttonStyle(.plain)
          }
        }
      }

      Section("Manual connection") {
        HStack {
          TextField("IP address", text: $manualAddress)
          Button("Connect") {
            connectManualAddress()
          }
          .disabled(
            manualAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              || model.isValidatingAddress
          )
        }
      }
    }
    .formStyle(.grouped)
  }

  private var cameraSettings: some View {
    Form {
      Section("Refresh rate") {
        LabeledContent("Maximum frame rate") {
          Text("\(Int(model.maxFrameRate)) FPS")
            .monospacedDigit()
        }

        Slider(
          value: Binding(
            get: { model.maxFrameRate },
            set: { model.setMaxFrameRate($0) }
          ),
          in: CameraPreferences.minimumFrameRate...CameraPreferences.maximumFrameRate,
          step: 1
        )

        Text("A lower value reduces network and printer load. Changes take effect immediately.")
          .font(AppTypography.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  private var notificationSettings: some View {
    Form {
      Section("Print completion") {
        LabeledContent(
          "Permission",
          value: model.notificationPermission.label
        )

        if model.notificationPermission == .notDetermined {
          Button("Enable notifications") {
            Task {
              await model.requestNotificationPermission()
            }
          }
        } else if model.notificationPermission == .denied {
          Text("Enable notifications for SnapMon in System Settings.")
            .foregroundStyle(.secondary)

          Button("Open Notification Settings") {
            openNotificationSettings()
          }
        } else {
          Text("A notification will be delivered when an observed print changes to Complete.")
            .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
  }

  private var appearanceSettings: some View {
    Form {
      Section("Inspector") {
        Toggle(
          "Translucent background",
          isOn: Binding(
            get: { model.isInspectorTranslucent },
            set: { model.setInspectorTranslucent($0) }
          )
        )

        Text("Reveals and blurs the desktop or other windows behind SnapMon.")
          .font(AppTypography.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  private func connectManualAddress() {
    let address = manualAddress
    Task {
      await model.connectManualAddress(address)
    }
  }

  private func openNotificationSettings() {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
      )
    else {
      return
    }

    NSWorkspace.shared.open(url)
  }
}

private enum SettingsTab: Hashable {
  case printer
  case camera
  case appearance
  case notifications
}
