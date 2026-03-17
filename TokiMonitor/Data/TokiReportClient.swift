import Foundation

/// Client for sending report queries to toki daemon via UDS.
final class TokiReportClient: Sendable {
    private let connection: TokiConnection

    init(connection: TokiConnection = TokiConnection()) {
        self.connection = connection
    }

    /// Query toki for usage summary.
    func querySummary(
        timeRange: TimeRange,
        timezone: String = TimeZone.current.identifier,
        completion: @escaping @Sendable (Result<[TokiModelSummary], Error>) -> Void
    ) {
        let query = "usage[\(timeRange.queryBucket)]"
        connection.sendReport(query: query, timezone: timezone) { result in
            switch result {
            case .success(let data):
                do {
                    let response = try JSONDecoder().decode(TokiReportResponse.self, from: data)
                    guard response.ok else {
                        completion(.failure(ReportError.queryFailed(response.error ?? "Unknown error")))
                        return
                    }
                    let summaries = response.data?
                        .compactMap(\.data)
                        .flatMap { $0 } ?? []
                    completion(.success(summaries))
                } catch {
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    enum ReportError: Error, LocalizedError {
        case queryFailed(String)

        var errorDescription: String? {
            switch self {
            case .queryFailed(let msg): "Report query failed: \(msg)"
            }
        }
    }
}
