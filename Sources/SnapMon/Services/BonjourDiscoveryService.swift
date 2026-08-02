import Foundation
import Network

final class BonjourDiscoveryService: @unchecked Sendable {
  func devices() -> AsyncStream<[DiscoveredDevice]> {
    AsyncStream { continuation in
      let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
        type: "_snapmaker._tcp",
        domain: nil
      )
      let parameters = NWParameters.tcp
      parameters.includePeerToPeer = false

      let browser = NWBrowser(for: descriptor, using: parameters)
      let queue = DispatchQueue(label: "local.snapmon.discovery")

      browser.browseResultsChangedHandler = { results, _ in
        let devices =
          results
          .compactMap(Self.device(from:))
          .reduce(into: [String: DiscoveredDevice]()) { devices, device in
            devices[device.id] = device
          }
          .values
          .sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
          }

        continuation.yield(devices)
      }

      browser.stateUpdateHandler = { state in
        if case .failed = state {
          continuation.finish()
        }
      }

      continuation.onTermination = { _ in
        browser.cancel()
      }

      continuation.yield([])
      browser.start(queue: queue)
    }
  }

  private static func device(from result: NWBrowser.Result) -> DiscoveredDevice? {
    guard case .service(let name, _, _, _) = result.endpoint,
      case .bonjour(let txtRecord) = result.metadata
    else {
      return nil
    }

    return DiscoveredDevice.fromBonjour(
      serviceName: name,
      txt: txtRecord.dictionary
    )
  }
}
