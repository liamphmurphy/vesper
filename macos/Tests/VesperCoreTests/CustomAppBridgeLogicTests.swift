import Foundation
import Testing
@testable import VesperCore

@Suite("CustomAppBridgeLogic")
struct CustomAppBridgeLogicTests {
    @Test func slugValidationRejectsReservedAndInvalid() {
        #expect(CustomAppBridgeLogic.validateSlug("finance-tracker") == nil)
        #expect(CustomAppBridgeLogic.validateSlug("docs") != nil)
        #expect(CustomAppBridgeLogic.validateSlug("slides") != nil)
        #expect(CustomAppBridgeLogic.validateSlug("designs") != nil)
        #expect(CustomAppBridgeLogic.validateSlug("Bad_Slug") != nil)
    }

    @Test func srcDocIncludesStrictCSPAndEscapesCloseScript() {
        let html = CustomAppBridgeLogic.buildCustomAppSrcDoc(
            slug: "budget",
            seq: 3,
            bundleJS: "console.log('</script><img src=x>');",
            bundleCSS: "body { color: red; }</style>",
            themeVars: ["--bg": "#111", "--fg": "#eee"]
        )
        #expect(html.contains("default-src 'none'"))
        #expect(html.contains("window.__VESPER_APP__"))
        #expect(!html.contains("</script><img"))
        #expect(!html.contains("red; }</style>"))
        #expect(html.contains("--bg: #111;"))
    }

    @Test func hostHTMLUsesSandboxedIframeAndAirPlaySupport() {
        let src = CustomAppBridgeLogic.buildCustomAppSrcDoc(slug: "tv", seq: 1, bundleJS: "", bundleCSS: nil, themeVars: [:])
        let host = CustomAppBridgeLogic.buildHostHTML(slug: "tv", name: "TV \"Live\"", srcDoc: src, themeVars: ["--bg": "#000"])
        #expect(host.contains("sandbox=\"allow-scripts\""))
        #expect(host.contains("x-webkit-airplay"))
        #expect(host.contains("webkitShowPlaybackTargetPicker"))
        #expect(host.contains("vesperCustomApp"))
    }

    @Test func videoEmbedResolvesYouTubeTwitchHlsAndLocalMedia() {
        let yt = CustomAppBridgeLogic.resolveVideoEmbed(rawURL: "https://youtu.be/dQw4w9WgXcQ?t=1m30s")
        #expect(yt?.provider == .youtube)
        #expect(yt?.embedURL == "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ?autoplay=1&rel=0&start=90")

        // Duplicate query parameter names must not trap Dictionary(uniqueKeysWithValues:)
        let ytDup = CustomAppBridgeLogic.resolveVideoEmbed(rawURL: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&v=other123456&t=10&t=20")
        #expect(ytDup?.provider == .youtube)
        #expect(ytDup?.embedURL == "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ?autoplay=1&rel=0&start=10")

        let tw = CustomAppBridgeLogic.resolveVideoEmbed(rawURL: "https://www.twitch.tv/videos/12345678", parentHost: "127.0.0.1")
        #expect(tw?.provider == .twitch)
        #expect(tw?.embedURL.contains("video=12345678&parent=127.0.0.1") == true)

        let uuid = "12345678-1234-4234-8234-123456789abc"
        #expect(CustomAppBridgeLogic.hlsRelayStreamId("vesper-hls:\(uuid)") == uuid)
        #expect(CustomAppBridgeLogic.localMediaId("vesper-media:\(uuid)") == uuid)
        #expect(CustomAppBridgeLogic.localMediaEmbed(rawURL: "vesper-media:\(uuid)", slug: "media")?.embedURL == "/api/v1/custom-apps/media/media/\(uuid)/content")
    }

    @Test func parseBridgeMessageValidatesChannelsAndPayloads() {
        let sql = CustomAppBridgeLogic.parseBridgeMessage([
            "channel": "vesper:custom-app",
            "id": "r1",
            "type": "sql",
            "payload": ["query": "SELECT 1", "params": [1, "a"]],
        ])
        #expect(sql == .sql(id: "r1", query: "SELECT 1", params: [.int(1), .string("a")]))

        let badImg = CustomAppBridgeLogic.parseBridgeMessage([
            "channel": "vesper:custom-app",
            "id": "r2",
            "type": "image",
            "payload": ["url": "http://insecure.example/a.png"],
        ])
        #expect(badImg == nil)

        let goodImg = CustomAppBridgeLogic.parseBridgeMessage([
            "channel": "vesper:custom-app",
            "id": "r3",
            "type": "image",
            "payload": ["url": "https://cdn.example/a.png"],
        ])
        #expect(goodImg == .image(id: "r3", url: "https://cdn.example/a.png"))

        let osPick = CustomAppBridgeLogic.parseBridgeMessage([
            "channel": "vesper:custom-app",
            "id": "r4",
            "type": "os-file-pick",
            "payload": ["multiple": true, "extensions": [".PNG", "jpg", "../bad"]],
        ])
        #expect(osPick == .osFilePick(id: "r4", multiple: true, extensions: ["png", "jpg"], title: nil))
    }

    @Test func customAppRouteResolvesWithoutShadowingEditors() {
        let reg = NativeRouteRegistry.standard(debug: false)
        #expect(reg.resolve("/apps/my-tracker")?.screen == .customApp)
        #expect(reg.resolve("/apps/my-tracker")?.params["slug"] == "my-tracker")
        #expect(reg.resolve("/apps/docs/d1")?.screen == .docEditor)
        #expect(reg.resolve("/apps/slides/s1")?.screen == .slidesEditor)
        #expect(reg.resolve("/apps/designs/g1")?.screen == .designEditor)
    }
}
