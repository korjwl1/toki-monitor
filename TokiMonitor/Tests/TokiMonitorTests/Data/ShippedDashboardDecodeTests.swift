import Testing
import Foundation
@testable import TokiMonitor

/// Bytes an actually-shipped build wrote, not bytes this build produced.
///
/// Every other decode fixture in this suite is built by encoding a HEAD Swift
/// object, so it always contains whatever keys HEAD happens to have. That makes
/// the whole suite blind to the one failure that matters here: a key this build
/// requires and no released build ever wrote. 748 tests passed while
/// `DashboardConfig` could not decode a single dashboard from v0.2.4.
///
/// This is the real `dashboardList[0]` from a v0.2.4 installation with the
/// identifiers and title replaced. Its key set is untouched — in particular it
/// has **no** `datasources` key.
@Suite("A dashboard written by the shipped release still opens")
@MainActor
struct ShippedDashboardDecodeTests {

    static let shippedJSON = #"""
{"annotations":[],"time":{"to":"now","from":"now-24h"},"schemaVersion":4,"refresh":"","uid":"shipped01","templating":{"list":[{"query":"all","type":"custom","id":"3324475B-98AF-472E-8B4B-B14028653D56","multi":true,"includeAll":true,"hide":0,"name":"provider","options":[{"selected":false,"value":"claude_code","text":"Claude"},{"selected":false,"value":"codex","text":"OpenAI"}],"refresh":1,"current":{"value":["$__all"],"text":["All"]},"label":"프로바이더"}]},"editable":true,"tags":[],"title":"Shipped Release Dashboard","id":"00000000-0000-0000-0000-000000000001","version":1,"panels":[{"collapsed":false,"id":"00000000-0000-0000-0000-000000000100","panelType":"stat","targets":[{"metric":"totalTokens","refId":"A","id":"511BF0A3-6960-4732-BE54-BAEC6EC21B8B"}],"options":{"thresholds":[],"tooltipMode":"single","lineWidth":2,"colorMode":"value","showHeader":true,"showThresholdMarkers":true,"legendPosition":"bottom","showLegend":true,"graphMode":"none","fillOpacity":0.1},"dataLinks":[],"gridPosition":{"row":0,"width":6,"height":1,"column":0},"title":"총 토큰","metric":"totalTokens"},{"collapsed":false,"id":"00000000-0000-0000-0000-000000000101","panelType":"stat","targets":[{"metric":"totalCost","refId":"A","id":"5DD4C1ED-1B73-449F-9E8C-2B271F185FD0"}],"options":{"thresholds":[],"tooltipMode":"single","lineWidth":2,"colorMode":"value","showHeader":true,"showThresholdMarkers":true,"legendPosition":"bottom","showLegend":true,"graphMode":"none","fillOpacity":0.1},"dataLinks":[],"gridPosition":{"row":0,"width":6,"height":1,"column":6},"title":"총 비용","metric":"totalCost"},{"collapsed":false,"id":"00000000-0000-0000-0000-000000000102","panelType":"stat","targets":[{"metric":"apiCalls","refId":"A","id":"85E7C9C9-6D95-4A82-B0C5-AC9555FB3783"}],"options":{"thresholds":[],"tooltipMode":"single","lineWidth":2,"colorMode":"value","showHeader":true,"showThresholdMarkers":true,"legendPosition":"bottom","showLegend":true,"graphMode":"none","fillOpacity":0.1},"dataLinks":[],"gridPosition":{"row":0,"width":6,"height":1,"column":12},"title":"API 호출","metric":"apiCalls"},{"collapsed":false,"id":"00000000-0000-0000-0000-000000000103","panelType":"stat","targets":[{"metric":"topModel","refId":"A","id":"35A4A927-7350-4011-AD5D-F52191A41F3E"}],"options":{"thresholds":[],"tooltipMode":"single","lineWidth":2,"colorMode":"value","showHeader":true,"showThresholdMarkers":true,"legendPosition":"bottom","showLegend":true,"graphMode":"none","fillOpacity":0.1},"dataLinks":[],"gridPosition":{"row":0,"width":6,"height":1,"column":18},"title":"최다 모델","metric":"topModel"},{"collapsed":false,"id":"00000000-0000-0000-0000-000000000104","panelType":"timeSeries","targets":[{"metric":"tokensByModel","refId":"A","id":"3E4B5336-F70A-47E4-BCB9-753456D6A55E"}],"options":{"thresholds":[],"tooltipMode":"single","lineWidth":2,"colorMode":"value","showHeader":true,"showThresholdMarkers":true,"legendPosition":"bottom","showLegend":true,"graphMode":"none","fillOpacity":0.1},"dataLinks":[],"gridPosition":{"row":1,"width":24,"height":3,"column":0},"title":"토큰 사용량 추이","metric":"tokensByModel"},{"collapsed":false,"id":"00000000-0000-0000-0000-000000000105","panelType":"pieChart","targets":[{"metric":"tokensByProject","refId":"A","id":"7D46D262-C27B-441E-8A86-304A22E69FAB"}],"options":{"thresholds":[],"tooltipMode":"single","lineWidth":2,"colorMode":"value","showHeader":true,"showThresholdMarkers":true,"legendPosition":"bottom","showLegend":true,"graphMode":"none","fillOpacity":0.1},"dataLinks":[],"gridPosition":{"row":4,"width":12,"height":3,"column":0},"title":"프로젝트별 사용량","metric":"tokensByProject"},{"collapsed":false,"id":"00000000-0000-0000-0000-000000000106","panelType":"barChart","targets":[{"metric":"eventsByModel","refId":"A","id":"61D047CA-E75B-4500-8914-CF0B13905F9B"}],"options":{"thresholds":[],"tooltipMode":"single","lineWidth":2,"colorMode":"value","showHeader":true,"showThresholdMarkers":true,"legendPosition":"bottom","showLegend":true,"graphMode":"none","fillOpacity":0.1},"dataLinks":[],"gridPosition":{"row":4,"width":12,"height":3,"column":12},"title":"API 호출 추이","metric":"eventsByModel"}]}
"""#

    private func shippedData() -> Data { Data(Self.shippedJSON.utf8) }

    @Test("v0.2.4 bytes decode at all")
    func shippedConfigDecodes() throws {
        let cfg = try JSONDecoder().decode(DashboardConfig.self, from: shippedData())
        #expect(cfg.uid == "shipped01")
        #expect(cfg.panels.count == 7)
        #expect(cfg.schemaVersion == 4)
    }

    /// The specific regression: a required decode of a key added after release.
    @Test("a key this build added is absent from released bytes and must not be required")
    func absentDatasourcesIsNotFatal() throws {
        let raw = try #require(
            try JSONSerialization.jsonObject(with: shippedData()) as? [String: Any]
        )
        #expect(raw["datasources"] == nil, "fixture must keep its released key set")

        let cfg = try JSONDecoder().decode(DashboardConfig.self, from: shippedData())
        #expect(cfg.datasources.isEmpty)
    }

    /// What the user actually loses when it throws: the store swallows the
    /// error and hands back a default whose uid is freshly generated, so the
    /// screen looks factory-reset rather than broken.
    @Test("released bytes survive the store's list decode")
    func shippedConfigSurvivesListDecode() throws {
        let list = Data(("[" + Self.shippedJSON + "]").utf8)
        let (decoded, decodedAll) = DashboardConfigStore.decodeList(list)
        #expect(decoded.count == 1, "a released dashboard must not be dropped")
        #expect(decodedAll)
        #expect(decoded.first?.uid == "shipped01")
    }

    /// Round-tripping released bytes must not lose the panels either.
    @Test("re-encoding released bytes keeps every panel")
    func roundTripKeepsPanels() throws {
        let cfg = try JSONDecoder().decode(DashboardConfig.self, from: shippedData())
        let again = try JSONDecoder().decode(
            DashboardConfig.self, from: try JSONEncoder().encode(cfg)
        )
        #expect(again.panels.count == cfg.panels.count)
        #expect(again.uid == cfg.uid)
        #expect(again.templating.list.count == cfg.templating.list.count)
    }
}
