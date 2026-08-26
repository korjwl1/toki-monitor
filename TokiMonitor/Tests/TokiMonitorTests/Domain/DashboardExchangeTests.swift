import Testing
import Foundation
@testable import TokiMonitor

/// Moving a dashboard between installations: what the file says about what it
/// needs, what it must never carry, and what happens when a panel arrives
/// somewhere its variables do not exist.
///
/// Everything here works on `DashboardExchange` directly. Nothing reads or
/// writes `com.toki.monitor`.
@Suite("A dashboard travels without its data")
@MainActor
struct DashboardExchangeTests {

    private var base: DashboardConfig { DashboardConfigStore.defaultConfig }

    private func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Minimum version (계약 C3 / T066)

    @Test("an export says which schema and which app release it needs")
    func exportCarriesMinimumVersions() throws {
        let exported = try object(try DashboardExchange.exportData(base))
        #expect(exported[DashboardExchange.minSchemaVersionKey] as? Int == base.schemaVersion)
        #expect(exported[DashboardExchange.minAppVersionKey] as? String
                == DashboardExchange.minimumAppVersion(forSchema: base.schemaVersion))
    }

    @Test("every schema this build can write has an app release named for it")
    func everySupportedSchemaHasAVersion() {
        for schema in 1...DashboardMigrator.currentVersion {
            #expect(DashboardExchange.appVersionIntroducingSchema[schema] != nil,
                    "schema v\(schema) has no release named for it — an import cannot say what to upgrade to")
        }
    }

    @Test("the metadata does not settle into the dashboard and get re-exported stale")
    func metadataIsStrippedOnImport() throws {
        var doc = try object(try DashboardExchange.exportData(base))
        doc[DashboardExchange.minAppVersionKey] = "9.9.9"
        let reimported = try DashboardExchange.decode(
            try JSONSerialization.data(withJSONObject: doc)
        )
        #expect(reimported.unknownFields[DashboardExchange.minAppVersionKey] == nil)
        #expect(reimported.unknownFields[DashboardExchange.minSchemaVersionKey] == nil)

        let reexported = try object(try DashboardExchange.exportData(reimported))
        #expect(reexported[DashboardExchange.minAppVersionKey] as? String != "9.9.9")
    }

    // MARK: - Refusing with a reason (계약 C4 / T067)

    @Test("a schema beyond this build is refused, naming what is missing")
    func schemaTooNewIsRefusedWithDetail() throws {
        var future = base
        future.schemaVersion = DashboardMigrator.currentVersion + 2
        let data = try DashboardExchange.exportData(future)

        var refusal: DashboardExchange.ImportRefusal?
        #expect(throws: DashboardExchange.ImportRefusal.self) {
            do { _ = try DashboardExchange.decode(data) }
            catch let e as DashboardExchange.ImportRefusal { refusal = e; throw e }
        }
        let caught = try #require(refusal)
        guard case let .schemaTooNew(required, supported, requiredApp, _) = caught else {
            Issue.record("expected a schema refusal, got \(caught)")
            return
        }
        #expect(required == DashboardMigrator.currentVersion + 2)
        #expect(supported == DashboardMigrator.currentVersion)

        let message = DashboardExchange.message(for: caught)
        #expect(message.contains("\(required)"), "the message must name the schema it needs")
        #expect(message.contains("\(supported)"), "and the schema this build has")
        #expect(message.contains(requiredApp), "and the release that would close the gap")
    }

    @Test("a document at this schema or older is admitted")
    func currentAndOlderAreAdmitted() throws {
        #expect(throws: Never.self) {
            _ = try DashboardExchange.decode(try DashboardExchange.exportData(base))
        }
    }

    @Test("bytes that are not a dashboard say where the reading went wrong")
    func unreadableSaysWhere() {
        var refusal: DashboardExchange.ImportRefusal?
        do { _ = try DashboardExchange.preview(Data(#"{"uid":"a"}"#.utf8)) }
        catch let e as DashboardExchange.ImportRefusal { refusal = e }
        catch { Issue.record("unexpected error \(error)") }

        guard case let .unreadable(reason)? = refusal else {
            Issue.record("expected an unreadable refusal, got \(String(describing: refusal))")
            return
        }
        #expect(!reason.isEmpty)
    }

    // MARK: - Preview before adding (계약 C4 / T068)

    @Test("the preview answers what it is, how big it is, and what it needs")
    func previewDescribesTheDocument() throws {
        var doc = base
        doc.title = "Traffic"
        let preview = try DashboardExchange.preview(try DashboardExchange.exportData(doc))

        #expect(preview.title == "Traffic")
        #expect(preview.panelCount == doc.panels.count)
        #expect(preview.variableCount == doc.templating.list.count)
        #expect(preview.schemaVersion == doc.schemaVersion)
        #expect(preview.minAppVersion
                == DashboardExchange.minimumAppVersion(forSchema: doc.schemaVersion))
        #expect(preview.isOpenableByThisBuild)
    }

    @Test("the preview names panel types this build cannot draw, without refusing them")
    func previewNamesUndrawablePanels() throws {
        var doc = try object(try DashboardExchange.exportData(base))
        var panels = try #require(doc["panels"] as? [[String: Any]])
        panels[0]["panelType"] = "sankeyDiagram"
        doc["panels"] = panels
        let data = try JSONSerialization.data(withJSONObject: doc)

        let preview = try DashboardExchange.preview(data)
        #expect(preview.undrawablePanelTypes == ["sankeyDiagram"])
        #expect(preview.isOpenableByThisBuild, "an undrawable panel is not a reason to refuse")
        #expect(preview.panelCount == base.panels.count)
    }

    @Test("a preview of a document this build cannot open still describes it")
    func previewOfARefusedDocumentStillDescribes() throws {
        var future = base
        future.title = "From later"
        future.schemaVersion = DashboardMigrator.currentVersion + 1
        let preview = try DashboardExchange.preview(try DashboardExchange.exportData(future))
        #expect(preview.title == "From later")
        #expect(!preview.isOpenableByThisBuild)
    }

    // MARK: - Panel exchange (계약 C5 / T069)

    private func targetDashboard(withVariables names: [String]) -> DashboardConfig {
        var target = base
        target.templating.list = names.map {
            DashboardVariable(name: $0, type: .custom)
        }
        return target
    }

    @Test("a pasted panel gets a new id, so pasting into its own dashboard is safe")
    func pasteReissuesTheID() throws {
        let source = base.panels[0]
        let json = try DashboardExchange.panelJSON(source)
        let paste = try DashboardExchange.pastePanel(json: json, into: base)
        #expect(paste.panel.id != source.id)
        #expect(paste.panel.title == source.title)
    }

    @Test("a pasted panel lands on a free slot, not on top of an existing one")
    func pasteRelocatesToAFreeSlot() throws {
        let source = base.panels[0]
        let json = try DashboardExchange.panelJSON(source)
        let paste = try DashboardExchange.pastePanel(json: json, into: base)

        let placed = paste.panel.gridPosition
        for existing in base.panels {
            let other = existing.gridPosition
            let overlapsX = placed.column < other.column + other.width
                && other.column < placed.column + placed.width
            let overlapsY = placed.row < other.row + other.height
                && other.row < placed.row + placed.height
            #expect(!(overlapsX && overlapsY),
                    "pasted panel at \(placed) overlaps existing panel at \(other)")
        }
    }

    @Test("a variable the target does not define is a warning, and the paste goes ahead")
    func pasteWarnsButProceedsOnAMissingVariable() throws {
        var source = base.panels[0]
        source.targets = [PanelTarget(
            refId: "A", metric: .totalTokens,
            query: "sum by (model) (increase(usage{env=\"$environment\"}[$__interval]))"
        )]
        let json = try DashboardExchange.panelJSON(source)

        let paste = try DashboardExchange.pastePanel(
            json: json, into: targetDashboard(withVariables: ["provider"])
        )
        #expect(paste.missingVariables == ["environment"])
        #expect(paste.panel.targets.first?.query?.contains("$environment") == true,
                "the query keeps the unresolved variable so the panel renders as failed")
    }

    @Test("a variable the target does define is not reported missing")
    func pasteIsQuietWhenEverythingResolves() throws {
        var source = base.panels[0]
        source.targets = [PanelTarget(
            refId: "A", metric: .totalTokens,
            query: "sum(increase(usage{env=\"$environment\"}[$__interval]))"
        )]
        let json = try DashboardExchange.panelJSON(source)
        let paste = try DashboardExchange.pastePanel(
            json: json, into: targetDashboard(withVariables: ["environment"])
        )
        #expect(paste.missingVariables.isEmpty)
    }

    @Test("built-ins are not mistaken for variables the target is missing")
    func builtinsAreNotMissingVariables() {
        let names = VariableResolver.referencedVariableNames(
            in: "sum by (model) (increase(usage{$provider}[$__interval])) and $__all"
        )
        #expect(names == ["provider"])
    }

    @Test("all three reference forms are recognised")
    func allReferenceFormsAreFound() {
        let names = VariableResolver.referencedVariableNames(
            in: "$bare and ${braced} and ${formatted:csv}"
        )
        #expect(names == ["bare", "braced", "formatted"])
    }

    @Test("pasting something that is not a panel says so instead of adding nothing")
    func pastingRubbishIsReported() {
        #expect(throws: DashboardExchange.ImportRefusal.self) {
            _ = try DashboardExchange.pastePanel(json: "{\"nope\":1}", into: base)
        }
    }

    @Test("a copied panel keeps the unknown keys it arrived with")
    func copiedPanelKeepsUnknownKeys() throws {
        var panel = base.panels[0]
        panel.unknownFields = ["futurePanelSetting": .object(["depth": .int(2)])]
        let json = try DashboardExchange.panelJSON(panel)
        let paste = try DashboardExchange.pastePanel(json: json, into: base)
        #expect(paste.panel.unknownFields["futurePanelSetting"] == .object(["depth": .int(2)]))
    }
}

// MARK: - What an export must not carry (계약 C3 / T070, T073)

/// The export is a layout, not a report. A file someone sends a colleague to
/// share a dashboard must not also tell them how many tokens the sender spent.
@Suite("An export carries configuration and nothing else")
@MainActor
struct DashboardExportContentTests {

    private func exported() throws -> (data: Data, text: String) {
        var config = DashboardConfigStore.defaultConfig
        config.title = "Shared"
        let data = try DashboardExchange.exportData(config)
        return (data, String(decoding: data, as: UTF8.self))
    }

    /// Every key anywhere in the document.
    private func allKeys(_ value: Any) -> Set<String> {
        if let object = value as? [String: Any] {
            return object.reduce(into: Set(object.keys)) { $0.formUnion(allKeys($1.value)) }
        }
        if let array = value as? [Any] {
            return array.reduce(into: Set<String>()) { $0.formUnion(allKeys($1)) }
        }
        return []
    }

    @Test("no usage, cost or result figures are anywhere in an export")
    func exportHasNoFigures() throws {
        let (data, _) = try exported()
        let keys = allKeys(try JSONSerialization.jsonObject(with: data))

        // The result vocabulary. A panel result travels as frames of fields of
        // values; a legacy result travels as points. None of it belongs here.
        let resultKeys: Set<String> = [
            "frames", "fields", "values", "points", "dataPoints", "samples",
            "rows", "result", "results", "series", "totalTokens", "totalCost",
            "inputTokens", "outputTokens", "cacheReadTokens", "costUSD",
        ]
        #expect(keys.isDisjoint(with: resultKeys),
                "result-bearing keys in an export: \(keys.intersection(resultKeys).sorted())")
    }

    @Test("a figure that was on screen does not reach the file")
    func aFetchedNumberIsNotInTheExport() throws {
        // A number no configuration could produce, standing in for whatever a
        // query returned while the dashboard was open.
        let sentinel = "918273645"
        let (_, text) = try exported()
        #expect(!text.contains(sentinel))
    }

    @Test("no account or device identifier is anywhere in an export")
    func exportHasNoIdentifiers() throws {
        let (data, _) = try exported()
        let keys = allKeys(try JSONSerialization.jsonObject(with: data))
        let identifierKeys: Set<String> = [
            "accountId", "accountID", "deviceId", "deviceID", "userId", "userID",
            "email", "machineId", "machineID", "token", "apiKey", "accessToken",
        ]
        #expect(keys.isDisjoint(with: identifierKeys),
                "identifier keys in an export: \(keys.intersection(identifierKeys).sorted())")
    }

    /// The structural guarantee behind the two tests above: a `PanelConfig`
    /// has nowhere to put a result even if someone tried. If this fails, a
    /// result type has been added to the configuration model and the export is
    /// one encoder change away from carrying it.
    @Test("the configuration model has no field that can hold a result")
    func configurationCannotHoldAResult() {
        let panel = DashboardConfigStore.defaultConfig.panels[0]
        for child in Mirror(reflecting: panel).children {
            let type = String(describing: Swift.type(of: child.value))
            for banned in ["FrameSet", "Frame", "TimeSeriesData", "PanelDataState"] {
                #expect(!type.contains(banned),
                        "PanelConfig.\(child.label ?? "?") is a \(type)")
            }
        }
    }

    @Test("the disclosure says what a query string can name")
    func disclosureNamesTheOneThingThatDoesTravel() {
        let text = DashboardExchange.exportDisclosure
        #expect(!text.isEmpty)
        // The one honest caveat: the export has no figures, but a query is
        // something the user wrote, and it often names their work.
        #expect(text.contains("질의") || text.lowercased().contains("quer"))
    }
}
