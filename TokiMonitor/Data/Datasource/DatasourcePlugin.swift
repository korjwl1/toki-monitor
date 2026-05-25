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
    /// Human-readable name shown in the data source picker.
    var displayName: String { get }
}
