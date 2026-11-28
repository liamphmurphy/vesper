import XCTest
@testable import VesperCore

final class ChatChartExpandedTests: XCTestCase {
    func testParsesStackedBarAreaHistogramHeatmapCalendarRadarSparkline() throws {
        // stacked-bar
        let stackedBar = try ChatChartSpec.parse("""
        {"type":"stacked-bar","categories":["Q1","Q2"],"series":[{"name":"A","values":[10,20]},{"name":"B","values":[5,15]}]}
        """).get()
        XCTAssertEqual(stackedBar.type, .stackedBar)
        XCTAssertEqual(stackedBar.tableRows().rows.count, 2)

        // area & stacked-area
        let area = try ChatChartSpec.parse("""
        {"type":"area","categories":["Mon","Tue"],"series":[{"name":"CPU","values":[30,45]}],"y":{"unit":"%"}}
        """).get()
        XCTAssertEqual(area.type, .area)
        XCTAssertEqual(area.tableRows().rows[0][1], "30%")

        let stackedArea = try ChatChartSpec.parse("""
        {"type":"stacked-area","categories":["Mon","Tue"],"series":[{"name":"In","values":[1,2]},{"name":"Out","values":[3,4]}]}
        """).get()
        XCTAssertEqual(stackedArea.type, .stackedArea)

        // histogram
        let hist = try ChatChartSpec.parse("""
        {"type":"histogram","title":"Latency","values":[10,12,15,20,25,30,40,42,45,50],"bins":4}
        """).get()
        XCTAssertEqual(hist.type, .histogram)
        XCTAssertEqual(hist.histogramBins.count, 4)
        XCTAssertEqual(hist.histogramBins.map(\.count).reduce(0, +), 10)
        XCTAssertEqual(hist.tableRows().rows.count, 4)

        // heatmap
        let hm = try ChatChartSpec.parse("""
        {"type":"heatmap","xLabels":["Mon","Tue"],"yLabels":["AM","PM"],"matrix":[[1,4],[2,null]]}
        """).get()
        XCTAssertEqual(hm.heatmap?.minValue, 1)
        XCTAssertEqual(hm.heatmap?.maxValue, 4)
        XCTAssertEqual(hm.tableRows().headers, ["Row", "Mon", "Tue"])
        XCTAssertEqual(hm.tableRows().rows[1][2], "—")

        // calendar-heatmap
        let cal = try ChatChartSpec.parse("""
        {"type":"calendar-heatmap","days":[{"date":"2026-11-02","value":5},{"date":"2026-11-01","value":2}]}
        """).get()
        XCTAssertEqual(cal.calendarDays.first?.date, "2026-11-01")
        XCTAssertEqual(cal.tableRows().rows.count, 2)

        // radar
        let radar = try ChatChartSpec.parse("""
        {"type":"radar","categories":["Speed","Cost","Quality","Safety"],"series":[{"name":"Model A","values":[8,7,9,9]}],"max":10}
        """).get()
        XCTAssertEqual(radar.radarMax, 10)
        XCTAssertEqual(radar.tableRows().headers, ["Axis", "Model A"])

        // sparkline
        let spark = try ChatChartSpec.parse("""
        {"type":"sparkline","title":"Error rate","values":[0.4,0.3,0.2,0.1],"delta":"-75%","tone":"positive","y":{"unit":"%"}}
        """).get()
        XCTAssertEqual(spark.sparklineValues.count, 4)
        XCTAssertEqual(spark.sparklineDelta, "-75%")

        // waterfall
        let wf = try ChatChartSpec.parse("""
        {"type":"waterfall","title":"Cashflow","y":{"unit":"$"},"items":[{"label":"Start","value":1000,"kind":"start"},{"label":"Rent","value":-400,"kind":"delta"},{"label":"Bonus","value":250,"kind":"delta"},{"label":"End","kind":"total"}]}
        """).get()
        XCTAssertEqual(wf.type, .waterfall)
        XCTAssertEqual(wf.waterfallItems.count, 4)
        XCTAssertEqual(wf.waterfallItems[1].startY, 1000)
        XCTAssertEqual(wf.waterfallItems[1].endY, 600)
        XCTAssertEqual(wf.waterfallItems[3].endY, 850)
        XCTAssertEqual(wf.tableRows().rows.count, 4)

        // sankey
        let sk = try ChatChartSpec.parse("""
        {"type":"sankey","title":"Budget","y":{"unit":"$"},"nodes":[{"id":"inc","label":"Income"},{"id":"tax","label":"Tax"},{"id":"save","label":"Savings"}],"links":[{"from":"inc","to":"tax","value":300},{"from":"inc","to":"save","value":700}]}
        """).get()
        XCTAssertEqual(sk.type, .sankey)
        XCTAssertEqual(sk.sankey?.nodes.count, 3)
        XCTAssertEqual(sk.sankey?.links.count, 2)
        XCTAssertEqual(sk.tableRows().rows[0], ["Income", "Tax", "$300"])

        // map
        let map = try ChatMapSpec.parse("""
        {"title":"PNW Trip","pins":[{"label":"Portland","lat":45.5231,"lon":-122.6765},{"label":"Seattle","lat":47.6062,"lon":-122.3321}],"routes":[{"label":"I-5","points":[[45.5231,-122.6765],[47.6062,-122.3321]]}]}
        """).get()
        XCTAssertEqual(map.pins.count, 2)
        XCTAssertEqual(map.routes.count, 1)
        XCTAssertGreaterThan(map.totalRouteKm, 200)
        XCTAssertLessThan(map.totalRouteKm, 300)
        let parsed = ChatTranscriptLogic.parseMessage("Trip:\n```map\n{\"pins\":[{\"label\":\"PDX\",\"lat\":45.5,\"lon\":-122.6}]}\n```")
        XCTAssertTrue(parsed.segments.contains { if case .map = $0 { return true }; return false })
    }

    // Each of these trapped converting a Double that was NaN, infinite or past Int's range to Int.

    func testHistogramClampsAnAbsurdBinCount() throws {
        let hist = try ChatChartSpec.parse("""
        {"type":"histogram","values":[1,2,3,4],"bins":1e19}
        """).get()
        XCTAssertEqual(hist.histogramBins.count, 30)
        let negative = try ChatChartSpec.parse("""
        {"type":"histogram","values":[1,2,3,4],"bins":-1e19}
        """).get()
        XCTAssertEqual(negative.histogramBins.count, 2)
    }

    func testHistogramBinsSurviveARangeThatOverflows() throws {
        let hist = try ChatChartSpec.parse("""
        {"type":"histogram","values":[-1.7e308,0,1.7e308],"bins":4}
        """).get()
        XCTAssertEqual(hist.histogramBins.count, 4)
        XCTAssertEqual(hist.histogramBins.map(\.count).reduce(0, +), 3, "every value lands in a bin")
    }

    func testHistogramBinsSurviveARangeThatUnderflows() {
        let bins = ChatChartSpec.computeHistogramBins(values: [0, 5e-324], binCount: 2, minVal: 0, maxVal: 5e-324)
        XCTAssertEqual(bins.map(\.count), [1, 1])
    }

    func testNiceTicksFallBackToEndpointsWhenTheStepDegenerates() {
        // max + pad overflows to infinity, so the step is infinite and hi / step is NaN.
        XCTAssertEqual(ChatChartSpec.niceTicks(min: 1.7e308, max: 1.7e308).count, 2)
        // The span underflows to a zero step, so lo / step is NaN.
        XCTAssertEqual(ChatChartSpec.niceTicks(min: 0, max: 5e-324), [0, 5e-324])
        XCTAssertEqual(ChatChartSpec.niceTicks(min: 0, max: 10), [0, 2.5, 5, 7.5, 10], "ordinary ranges still work")
    }

    func testInvalidSpecsReturnDescriptiveErrors() {
        XCTAssertThrowsError(try ChatChartSpec.parse("""
        {"type":"radar","categories":["A","B"],"series":[{"name":"S","values":[1,2]}]}
        """).get())
        XCTAssertThrowsError(try ChatChartSpec.parse("""
        {"type":"heatmap","xLabels":["A"],"yLabels":["1","2"],"matrix":[[1]]}
        """).get())
        XCTAssertThrowsError(try ChatChartSpec.parse("""
        {"type":"histogram","values":[]}
        """).get())
        XCTAssertThrowsError(try ChatChartSpec.parse("""
        {"type":"sparkline","values":[1]}
        """).get())
    }

    func testStatsBlockValidAndInvalid() throws {
        let stats = try ChatStatsSpec.parse("""
        {"title":"Weekly KPIs","items":[{"label":"Latency p95","value":42,"unit":"ms","delta":"-14%","tone":"positive","sparkline":[55,50,48,42]},{"label":"Errors","value":"0.1%","delta":"+0.02%","tone":"negative"}]}
        """).get()
        XCTAssertEqual(stats.items.count, 2)
        XCTAssertEqual(stats.items[0].value, "42 ms")
        XCTAssertEqual(stats.items[0].sparkline.count, 4)

        let segments = ChatTranscriptLogic.parseSegments("```stats\n{\"items\":[]}\n```")
        guard case .invalidBlock(let kind, _, _) = segments.first else {
            return XCTFail("Expected invalidBlock for empty stats")
        }
        XCTAssertEqual(kind, "stats")
    }
}
