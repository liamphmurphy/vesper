import Testing
@testable import VesperCore

struct NavigationHistoryTests {
    @Test func initialStateCannotNavigateBackOrForward() {
        var history = NavigationHistory(initial: "/knowledge")
        #expect(history.current == "/knowledge")
        #expect(!history.canGoBack)
        #expect(!history.canGoForward)
        #expect(history.count == 1)
        let back = history.goBack()
        let forward = history.goForward()
        #expect(back == nil)
        #expect(forward == nil)
    }

    @Test func backAndForwardAcrossKnowledgeAndPDF() {
        var history = NavigationHistory(initial: "/wiki/architecture-notes")
        let pdfPath = "/pdf?src=%2Fapi%2Fv1%2Ffiles%2Fabc&title=Spec"

        let moved = history.navigate(to: pdfPath)
        #expect(moved)
        #expect(history.current == pdfPath)
        #expect(history.canGoBack)
        #expect(!history.canGoForward)

        let back = history.goBack()
        #expect(back == "/wiki/architecture-notes")
        #expect(history.current == "/wiki/architecture-notes")
        #expect(!history.canGoBack)
        #expect(history.canGoForward)

        let forward = history.goForward()
        #expect(forward == pdfPath)
        #expect(history.current == pdfPath)
        #expect(history.canGoBack)
        #expect(!history.canGoForward)
    }

    @Test func distinguishesQueryVariantsLikeMockupEditMode() {
        var history = NavigationHistory(initial: "/chat/chat-1")
        let openedEdit = history.navigate(to: "/artifacts/art-1?edit=1")
        let finishedEdit = history.navigate(to: "/artifacts/art-1")
        #expect(openedEdit)
        #expect(finishedEdit)

        let firstBack = history.goBack()
        let secondBack = history.goBack()
        let thirdBack = history.goBack()
        #expect(firstBack == "/artifacts/art-1?edit=1")
        #expect(secondBack == "/chat/chat-1")
        #expect(thirdBack == nil)
    }

    @Test func pushingAfterBackTruncatesForwardHistory() {
        var history = NavigationHistory(initial: "/chat/1")
        history.navigate(to: "/artifacts/a/review")
        history.navigate(to: "/artifacts/a")

        let backToReview = history.goBack()
        #expect(backToReview == "/artifacts/a/review")
        #expect(history.canGoForward)

        let movedToKnowledge = history.navigate(to: "/knowledge")
        #expect(movedToKnowledge)
        #expect(!history.canGoForward)
        let forward = history.goForward()
        let back1 = history.goBack()
        let back2 = history.goBack()
        #expect(forward == nil)
        #expect(back1 == "/artifacts/a/review")
        #expect(back2 == "/chat/1")
    }

    @Test func consecutiveDuplicateNavigationIsIgnoredAndPreservesForwardStack() {
        var history = NavigationHistory(initial: "/chat/1")
        history.navigate(to: "/knowledge")
        let back = history.goBack()
        #expect(back == "/chat/1")

        let duplicate = history.navigate(to: "/chat/1")
        #expect(!duplicate)
        #expect(history.count == 2)
        #expect(history.canGoForward)
        let forward = history.goForward()
        #expect(forward == "/knowledge")
    }

    @Test func replaceOverwritesRedirectWithoutLeavingTrapInBackStack() {
        var history = NavigationHistory(initial: "/")
        let replacedRoot = history.navigate(to: "/chat?new", replace: true)
        #expect(replacedRoot)
        #expect(history.current == "/chat?new")
        #expect(!history.canGoBack)
        #expect(history.count == 1)

        history.navigate(to: "/artifacts/note-1")
        let replacedNote = history.navigate(to: "/wiki/my-note", replace: true)
        #expect(replacedNote)
        #expect(history.current == "/wiki/my-note")
        #expect(history.canGoBack)
        let back = history.goBack()
        #expect(back == "/chat?new")
        #expect(!history.canGoBack)
    }

    @Test func replaceCollapsesWhenRedirectMatchesPreviousEntry() {
        var history = NavigationHistory(initial: "/wiki/my-note")
        history.navigate(to: "/artifacts/note-1")
        let collapsed = history.navigate(to: "/wiki/my-note", replace: true)
        #expect(collapsed)
        #expect(history.current == "/wiki/my-note")
        #expect(!history.canGoBack)
        #expect(history.count == 1)
    }

    @Test func boundsHistoryToMaxEntries() {
        var history = NavigationHistory(initial: "/0", maxEntries: 3)
        history.navigate(to: "/1")
        history.navigate(to: "/2")
        history.navigate(to: "/3")

        #expect(history.count == 3)
        #expect(history.current == "/3")
        let back1 = history.goBack()
        let back2 = history.goBack()
        let back3 = history.goBack()
        #expect(back1 == "/2")
        #expect(back2 == "/1")
        #expect(back3 == nil)
    }

    @Test func normalizesBlankPathsToRoot() {
        var history = NavigationHistory(initial: "   ")
        #expect(history.current == "/")
        let moved = history.navigate(to: "")
        #expect(!moved)
    }
}
