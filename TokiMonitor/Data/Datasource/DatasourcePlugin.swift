import Foundation

/// Perses-style datasource plugin.
///
/// Each plugin owns a `kind` string and knows how to execute a PromQL range
/// query against its backend. Plugins are looked up by kind through
/// `DatasourceRegistry`.
///
/// Conforms to the legacy `QueryDataSource` protocol so existing call sites
/// (DashboardViewModel.fetchData) keep working without change.
protocol DatasourcePlugin: QueryDataSource {
    /// Unique identifier for this datasource plugin kind (e.g. "toki-local").
    var kind: String { get }
}

extension DatasourcePlugin {
    /// Convenience accessor for the localized name. Presentation owns the
    /// kind-to-string mapping (`DatasourceKindDisplay`) so this stays a
    /// thin pass-through that Data callers can use without depending on
    /// the Domain `Localization` helper directly.
    var displayName: String { DatasourceKindDisplay.name(for: kind) }
}
