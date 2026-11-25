import SwiftUI
import VesperCore

/// Handles `/` landing resolution (navigating directly to `/chat?new` with the most-used persona)
/// and legacy `/apps/docs`, `/apps/slides`, `/apps/designs` redirects into Knowledge without
/// loading a WKWebView.
struct RootLandingScreen: View {
    @Environment(NativeScreenContext.self) private var context
    @Environment(\.vesperTheme) private var theme

    @State private var redirected = false

    private static let bootRequest = API.getBootstrap()
    private static let personasRequest = API.listPersonas()

    var body: some View {
        let p = theme.palette
        let bootEntry = context.store.entry(Self.bootRequest)
        let personasEntry = context.store.entry(Self.personasRequest)

        VStack(spacing: 12) {
            ProgressView().controlSize(.regular)
            Text("Opening Vesper\u{2026}")
                .font(.system(size: 13))
                .foregroundStyle(p.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if let redirect = AppsHomeLogic.knowledgeRedirectPath(for: context.match.path) {
                redirected = true
                context.navigate(redirect, replace: true)
                return
            }
            context.store.load(Self.bootRequest)
            context.store.load(Self.personasRequest)
            tryResolve(boot: bootEntry.data, personas: personasEntry.data, personasFetching: personasEntry.isFetching)
        }
        .onChange(of: "\(bootEntry.data != nil)|\(personasEntry.data != nil)|\(personasEntry.isFetching)|\(personasEntry.error != nil)") { _, _ in
            tryResolve(boot: bootEntry.data, personas: personasEntry.data, personasFetching: personasEntry.isFetching)
        }
    }

    private func tryResolve(boot: API.Bootstrap?, personas: API.PersonaList?, personasFetching: Bool) {
        guard !redirected else { return }
        if let redirect = AppsHomeLogic.knowledgeRedirectPath(for: context.match.path) {
            redirected = true
            context.navigate(redirect, replace: true)
            return
        }
        guard let boot, !personasFetching else { return }
        redirected = true
        let target = LandingLogic.landingPath(
            me: boot.me,
            personas: personas?.personas ?? [],
            defaultPersonaId: personas?.defaultPersonaId
        )
        context.navigate(target, replace: true)
    }
}
