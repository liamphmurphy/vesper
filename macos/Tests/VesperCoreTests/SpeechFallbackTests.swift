import XCTest
@testable import VesperCore

final class SpeechFallbackTests: XCTestCase {
    func testALimitSaysWhichLimitAndWhenItLifts() {
        let body = Data(#"{"code":"conflict","message":"Gemini's daily limit of 100 requests is used up. It resets at midnight Pacific time."}"#.utf8)
        XCTAssertEqual(SpeechLimitMessage.from(body), "Gemini's daily limit of 100 requests is used up. It resets at midnight Pacific time.")
    }

    func testAnUnreadableLimitStillSaysSomething() {
        XCTAssertEqual(SpeechLimitMessage.from(Data()), SpeechLimitMessage.fallback)
        XCTAssertEqual(SpeechLimitMessage.from(Data("<html>Too Many Requests</html>".utf8)), SpeechLimitMessage.fallback)
        XCTAssertEqual(SpeechLimitMessage.from(Data(#"{"message":"  "}"#.utf8)), SpeechLimitMessage.fallback)
    }

    func testTheMacVoiceReadsWordsNotMarkdown() {
        XCTAssertEqual(SystemVoiceText.plain("Sure, I **merged** it. See [the PR](https://example.com) and `main`."), "Sure, I merged it. See the PR and main.")
        XCTAssertEqual(SystemVoiceText.plain("Plain words stay."), "Plain words stay.")
    }
}
