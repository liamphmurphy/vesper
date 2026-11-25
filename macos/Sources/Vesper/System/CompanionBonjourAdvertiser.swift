import Foundation

/// Advertises Vesper's companion TLS listener over Bonjour (`_vesper._tcp`) while companion
/// access is enabled so paired iPhones on the same Wi-Fi network can discover the Mac even if
/// its DHCP IP changes.
@MainActor
final class CompanionBonjourAdvertiser: NSObject, NetServiceDelegate {
    private var service: NetService?
    private var publishedPort: Int = 0

    func update(enabled: Bool, port: Int) {
        if !enabled || port <= 0 {
            stop()
            return
        }
        if service != nil && publishedPort == port { return }
        stop()

        let hostName = ProcessInfo.processInfo.hostName
            .replacingOccurrences(of: ".local", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let svc = NetService(domain: "local.", type: "_vesper._tcp.", name: hostName.isEmpty ? "Vesper" : hostName, port: Int32(port))
        svc.delegate = self
        if let localHost = ProcessInfo.processInfo.hostName.data(using: .utf8) {
            svc.setTXTRecord(NetService.data(fromTXTRecord: ["host": localHost]))
        }
        svc.publish()
        self.service = svc
        self.publishedPort = port
    }

    func stop() {
        service?.stop()
        service = nil
        publishedPort = 0
    }
}
