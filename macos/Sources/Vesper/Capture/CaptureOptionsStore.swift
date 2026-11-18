import Foundation
import Observation
import VesperCore

/// Personas and projects for Quick Capture and the send picker, from GET /api/v1/personas and
/// /api/v1/projects. Refreshed every 10 minutes and whenever a panel opens on stale data.
@MainActor
@Observable
final class CaptureOptionsStore {
    private(set) var personas: [PersonaSummary] = []
    private(set) var defaultPersonaId = ""
    private(set) var projects: [ProjectSummary] = []
    private(set) var reachable = true
    @ObservationIgnored private var refreshedAt: Date?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored var clientProvider: () -> APIClient? = { nil }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 10 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
    }

    /// Refreshes when the data is older than `maxAge` seconds.
    func refreshIfStale(maxAge: TimeInterval = 60) async {
        if let at = refreshedAt, Date().timeIntervalSince(at) < maxAge { return }
        await refresh()
    }

    func refresh() async {
        guard !inFlight, let client = clientProvider() else { return }
        inFlight = true
        defer { inFlight = false }
        async let p = try? client.request("GET", "/api/v1/personas")
        async let q = try? client.request("GET", "/api/v1/projects")
        let (personaData, projectData) = await (p, q)
        reachable = personaData != nil || projectData != nil
        if let personaData {
            let list = CaptureOptions.parsePersonas(personaData)
            personas = list.personas
            defaultPersonaId = list.defaultPersonaId
        }
        if let projectData { projects = CaptureOptions.parseProjects(projectData) }
        if reachable { refreshedAt = Date() }
    }
}
