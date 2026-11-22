import Foundation

// Mirrors `characterStateForStatus` in `web/lib/persona-character.ts`, so a persona acts out the
// same thing in the native chat as on the web.
extension CharacterState {
    /// The live character state for a running chat turn whose current scene is `kind`.
    /// Stopping freezes the character; a turn waiting on the person's approval asks for them
    /// whatever its scene is.
    public static func forActivity(_ kind: ActivitySceneKind, awaiting: Bool = false, stopping: Bool = false) -> CharacterState {
        if stopping { return .staticState }
        if awaiting { return .needsYou }
        switch kind {
        case .thinking, .nextStep, .memory, .memorySave, .inbox, .choices, .subagent, .learning:
            return .thinking
        case .readingCode, .searchingCode, .wiki, .ticketLookup, .chatHistory, .repoSearch, .web, .webPage,
             .savedLinks, .research, .library, .projects, .imageView, .designView, .repoHistory, .finance,
             .runs, .schedule:
            return .reading
        case .writingCode, .tests, .build, .install, .terminal, .github, .commit, .push, .pullRequest,
             .repoAttach, .playground, .customApp, .database, .http, .workflow:
            return .coding
        case .writingReply, .canvas, .canvasComment, .design, .image, .video, .videoRender, .audioRender,
             .chart, .diagram, .app, .pdf, .persona, .space, .tickets, .financeSort:
            return .creating
        case .connector, .secret:
            return .needsYou
        }
    }
}
