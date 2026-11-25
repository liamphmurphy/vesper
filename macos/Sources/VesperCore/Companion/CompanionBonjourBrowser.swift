import Foundation
import Network

/// Watches `_vesper._tcp` on the local network via Bonjour (`NWBrowser`) so the companion app
/// can still find the Mac on LAN even if DHCP assigns a new IP address.
public final class CompanionBonjourBrowser: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.liamphmurphy.vesper.bonjour-browser")
    private var browser: NWBrowser?
    private let lock = NSLock()
    private var discoveredHosts: [String] = []
    private var onUpdate: (@Sendable ([String]) -> Void)?

    public init() {}

    public var currentHosts: [String] {
        lock.withLock { discoveredHosts }
    }

    public func start(serviceType: String = "_vesper._tcp", onUpdate: (@Sendable ([String]) -> Void)? = nil) {
        stop()
        self.onUpdate = onUpdate
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: serviceType, domain: "local.")
        let params = NWParameters()
        params.includePeerToPeer = false
        let browser = NWBrowser(for: descriptor, using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            var hosts: [String] = []
            for result in results {
                if case .bonjour(let txt) = result.metadata,
                   let host = txt["host"], !host.isEmpty
                {
                    hosts.append(host)
                }
                if case .service(let name, _, let domain, _) = result.endpoint {
                    let candidate = "\(name).\(domain)".trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    if !candidate.isEmpty && !hosts.contains(candidate) {
                        hosts.append(candidate)
                    }
                }
            }
            self.lock.withLock { self.discoveredHosts = hosts }
            self.onUpdate?(hosts)
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }
}
