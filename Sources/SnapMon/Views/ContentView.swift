import SwiftUI

struct ContentView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    Group {
      if model.selectedPrinter == nil {
        SetupView()
      } else {
        MonitorView()
      }
    }
    .task {
      model.start()
    }
    .alert(
      "SnapMon",
      isPresented: Binding(
        get: { model.lastErrorMessage != nil },
        set: { isPresented in
          if !isPresented {
            model.dismissError()
          }
        }
      )
    ) {
      Button("OK") {
        model.dismissError()
      }
    } message: {
      Text(model.lastErrorMessage ?? "An unknown error occurred.")
    }
  }
}
