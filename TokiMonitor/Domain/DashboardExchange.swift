import Foundation

/// Moving a dashboard, or one panel of it, between installations.
///
/// Everything here works on **configuration** only. A dashboard is what the
/// user built; results are what a query happened to return this afternoon.
/// Sending the second along with the first would put the user's usage and cost
/// figures into a file they thought was a layout (계약 C3).
enum DashboardExchange {

    // MARK: - Version metadata (계약 C3 / T066)

    /// Keys added to an exported document, and stripped again on import so they
    /// never accumulate inside a saved dashboard.
    static let minAppVersionKey = "minAppVersion"
    static let minSchemaVersionKey = "minSchemaVersion"

    /// The app release that first wrote each dashboard schema.
    ///
    /// **A schema bump MUST add its row here.** The value is what an import
    /// tells the reader to upgrade to, and a missing row makes that sentence
    /// vaguer than it needs to be. It is advisory only: the gate that actually
    /// admits or refuses a document is the schema number, which is exact.
    static let appVersionIntroducingSchema: [Int: String] = [
        1: "0.1.0",
        2: "0.1.0",
        3: "0.2.0",
        4: "0.2.5",
    ]

    static var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// The oldest app release that can open a document at this schema.
    static func minimumAppVersion(forSchema schema: Int) -> String {
        if let known = appVersionIntroducingSchema[schema] { return known }
        // No row: either the schema is newer than anything this build knows —
        // in which case no version we can name will do — or someone bumped the
        // schema without filling the table in. Naming this build is the closest
        // true statement available in both cases.
        return currentAppVersion
    }

    /// What the user is told before a dashboard leaves the machine.
    ///
    /// The export carries no results, but a query string is something the user
    /// wrote, and what they wrote often names their projects and the models
    /// they use. That is not a leak to fix — it is the query — so it is
    /// disclosed rather than stripped.
    static var exportDisclosure: String {
        L.tr("""
             내보낸 파일에는 질의 결과·사용량·비용 수치와 계정·기기 식별자가 들어가지 않습니다. \
             다만 질의 문자열은 사용자가 쓴 그대로 담기므로, 프로젝트명이나 모델명이 포함될 수 있습니다.
             """,
             """
             The exported file carries no query results, usage or cost figures, and no account or \
             device identifiers. Query strings go out as written, so they may name your projects \
             and the models you use.
             """)
    }

    // MARK: - Export

    /// Serialise a dashboard for sharing: its configuration, plus the minimum
    /// versions needed to open it.
    static func exportData(_ config: DashboardConfig) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(config)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw DashboardImportError.invalidJSON
        }
        object[minSchemaVersionKey] = config.schemaVersion
        object[minAppVersionKey] = minimumAppVersion(forSchema: config.schemaVersion)
        return try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys]
        )
    }

    static func exportString(_ config: DashboardConfig) throws -> String {
        String(decoding: try exportData(config), as: UTF8.self)
    }

    // MARK: - Import (계약 C4)

    /// What the reader sees before deciding to add a document.
    ///
    /// Enough to answer "is this the dashboard I meant, and will it work here?"
    /// without adding it first and undoing it after.
    struct Preview: Equatable {
        var title: String
        var uid: String
        var panelCount: Int
        var variableCount: Int
        var schemaVersion: Int
        var minAppVersion: String
        /// Panel types in the document that this build has no renderer for.
        /// They are kept and shown as placeholders, not dropped — the reader
        /// should know before the import, not after.
        var undrawablePanelTypes: [String]

        var isOpenableByThisBuild: Bool {
            schemaVersion <= DashboardMigrator.currentVersion
        }
    }

    enum ImportRefusal: Error, Equatable {
        /// The document needs a schema this build cannot write.
        case schemaTooNew(required: Int, supported: Int, requiredAppVersion: String,
                          thisAppVersion: String)
        /// The bytes are not a dashboard, with the place and the reason.
        case unreadable(String)
    }

    /// Read a document far enough to describe it, without committing to it.
    static func preview(_ data: Data) throws -> Preview {
        let config: DashboardConfig
        do {
            config = try decodeConfig(data)
        } catch {
            throw ImportRefusal.unreadable(describe(error))
        }
        let declaredSchema = declaredMinSchemaVersion(in: data) ?? config.schemaVersion
        return Preview(
            title: config.title,
            uid: config.uid,
            panelCount: config.panels.count,
            variableCount: config.templating.list.count,
            schemaVersion: declaredSchema,
            minAppVersion: declaredMinAppVersion(in: data)
                ?? minimumAppVersion(forSchema: declaredSchema),
            undrawablePanelTypes: config.panels
                .filter { $0.panelType == .unknown }
                .compactMap(\.unknownPanelTypeRaw)
                .reduced()
        )
    }

    /// Read a document and refuse it if this build cannot open it.
    ///
    /// The refusal names what is missing — the schema it needs, the schema this
    /// build has, and the release that would close the gap. "Incompatible
    /// version" on its own leaves the reader with nothing to do (계약 C4).
    static func decode(_ data: Data) throws -> DashboardConfig {
        let preview = try preview(data)
        guard preview.isOpenableByThisBuild else {
            throw ImportRefusal.schemaTooNew(
                required: preview.schemaVersion,
                supported: DashboardMigrator.currentVersion,
                requiredAppVersion: preview.minAppVersion,
                thisAppVersion: currentAppVersion
            )
        }
        return try decodeConfig(data)
    }

    /// Decode without the version gate.
    ///
    /// The gate in `decode` is right for a file the user picked: they still
    /// have the file, and the refusal tells them which release opens it. It is
    /// wrong for a document arriving over the settings sync channel, where a
    /// refusal would leave the entry stranded on the server and force every
    /// later push from this machine to either overwrite it or stall. Such a
    /// document decodes here with `isReadOnlyForThisBuild` true, and the store
    /// writes its original bytes back rather than a re-encode (계약 C2).
    static func decodeIgnoringSchemaGate(_ data: Data) throws -> DashboardConfig {
        do {
            return try decodeConfig(data)
        } catch {
            throw ImportRefusal.unreadable(describe(error))
        }
    }

    /// Decode without the version gate, with the export metadata removed so it
    /// does not settle into `unknownFields` and get re-exported stale.
    private static func decodeConfig(_ data: Data) throws -> DashboardConfig {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return try decoder.decode(DashboardConfig.self, from: data)
        }
        object.removeValue(forKey: minAppVersionKey)
        object.removeValue(forKey: minSchemaVersionKey)
        let stripped = try JSONSerialization.data(withJSONObject: object)
        return try decoder.decode(DashboardConfig.self, from: stripped)
    }

    private static func declaredMinSchemaVersion(in data: Data) -> Int? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?
            .flatMap { $0[minSchemaVersionKey] as? Int }
    }

    private static func declaredMinAppVersion(in data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?
            .flatMap { $0[minAppVersionKey] as? String }
    }

    /// A refusal in the reader's words.
    static func message(for refusal: ImportRefusal) -> String {
        switch refusal {
        case let .schemaTooNew(required, supported, requiredAppVersion, thisAppVersion):
            return L.tr(
                "이 대시보드는 스키마 v\(required)로 저장되어 있습니다. 이 버전(\(thisAppVersion))은 v\(supported)까지 읽습니다. 열려면 \(requiredAppVersion) 이상이 필요합니다.",
                "This dashboard is stored at schema v\(required). This version (\(thisAppVersion)) reads up to v\(supported). Opening it needs \(requiredAppVersion) or newer."
            )
        case let .unreadable(reason):
            return reason
        }
    }

    /// Where a decode went wrong, in a form someone can act on.
    static func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else {
            return error.localizedDescription
        }
        switch decoding {
        case let .keyNotFound(key, ctx):
            return L.tr("필수 항목 '\(key.stringValue)'이 없습니다 (\(path(ctx)))",
                        "missing required field '\(key.stringValue)' at \(path(ctx))")
        case let .typeMismatch(_, ctx):
            return L.tr("형식이 맞지 않습니다 (\(path(ctx)))", "type mismatch at \(path(ctx))")
        case let .valueNotFound(_, ctx):
            return L.tr("값이 비어 있습니다 (\(path(ctx)))",
                        "null where a value is required at \(path(ctx))")
        case .dataCorrupted:
            return L.tr("JSON을 읽을 수 없습니다", "not valid JSON")
        @unknown default:
            return L.tr("불러오기 실패", "import failed")
        }
    }

    private static func path(_ ctx: DecodingError.Context) -> String {
        let joined = ctx.codingPath
            .map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }
            .joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return joined.isEmpty ? "root" : joined
    }

    // MARK: - Panel exchange (계약 C5)

    /// One panel as JSON, for pasting into another dashboard.
    ///
    /// This is what stands in for library panels, which are out of scope: a
    /// panel someone spent time on can be moved without rebuilding it.
    static func panelJSON(_ panel: PanelConfig) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(panel), as: UTF8.self)
    }

    /// A panel prepared for a target dashboard, and what will not resolve there.
    struct PanelPaste: Equatable {
        var panel: PanelConfig
        /// Variables the panel's queries name that the target does not define.
        /// The paste goes ahead anyway — the query keeps the unresolved
        /// variable and the panel renders as failed, which the reader can fix
        /// by adding the variable. Refusing the paste would leave them with
        /// nothing to fix (계약 C5).
        var missingVariables: [String]
    }

    /// Read a panel from JSON and place it in `target`.
    ///
    /// - a fresh `id`, so pasting into the dashboard it came from does not
    ///   collide with the original
    /// - `gridPosition` moved to the first free slot in the target
    /// - the variables it names that the target does not have, reported
    static func pastePanel(json: String, into target: DashboardConfig) throws -> PanelPaste {
        guard let data = json.data(using: .utf8) else {
            throw ImportRefusal.unreadable(
                L.tr("붙여넣은 내용이 텍스트가 아닙니다", "the pasted content is not text")
            )
        }
        return try pastePanel(data: data, into: target)
    }

    static func pastePanel(data: Data, into target: DashboardConfig) throws -> PanelPaste {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var panel: PanelConfig
        do {
            panel = try decoder.decode(PanelConfig.self, from: data)
        } catch {
            throw ImportRefusal.unreadable(describe(error))
        }

        panel.id = UUID()
        panel.gridPosition = DashboardGridLayout.firstAvailablePosition(
            width: max(1, panel.gridPosition.width),
            height: max(1, panel.gridPosition.height),
            existing: target.panels
        )

        let defined = Set(target.templating.list.map(\.name))
        let missing = referencedVariableNames(in: panel)
            .filter { !defined.contains($0) }
            .sorted()
        return PanelPaste(panel: panel, missingVariables: missing)
    }

    /// Every variable a panel's queries name, built-ins excluded.
    static func referencedVariableNames(in panel: PanelConfig) -> [String] {
        var templates = panel.targets.compactMap(\.query)
        if let query = panel.resolvedTokiQuery?.query { templates.append(query) }
        var names: Set<String> = []
        for template in templates {
            names.formUnion(VariableResolver.referencedVariableNames(in: template))
        }
        return names.sorted()
    }

    /// The sentence shown when a pasted panel names variables the target lacks.
    static func missingVariableWarning(_ names: [String]) -> String {
        let list = names.joined(separator: ", ")
        return L.tr(
            "이 대시보드에 없는 변수를 참조합니다: \(list). 패널은 붙여넣었고, 해당 질의는 변수를 추가할 때까지 실패 상태로 표시됩니다.",
            "It references variables this dashboard does not define: \(list). The panel was pasted; those queries stay in a failed state until you add them."
        )
    }
}

private extension Array where Element == String {
    /// Distinct, in order of first appearance.
    func reduced() -> [String] {
        var seen: Set<String> = []
        return filter { seen.insert($0).inserted }
    }
}
