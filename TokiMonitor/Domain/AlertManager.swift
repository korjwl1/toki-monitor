import Foundation
import UserNotifications

/// Manages alert rules, evaluation, and macOS notifications.
@MainActor
final class AlertManager {
    private static let storeKey = "dashboardAlertRules"
    private var evaluationTimer: Timer?

    func startEvaluation(dataProvider: @escaping () -> Double?) {
        evaluationTimer?.invalidate()
        evaluationTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluateAll(dataProvider: dataProvider)
            }
        }
    }

    func stopEvaluation() {
        evaluationTimer?.invalidate()
        evaluationTimer = nil
    }

    // MARK: - CRUD

    func rules(for panelID: UUID) -> [AlertRule] {
        loadAll().filter { $0.panelID == panelID }
    }

    func allRules() -> [AlertRule] {
        loadAll()
    }

    func addRule(_ rule: AlertRule) {
        var all = loadAll()
        all.append(rule)
        saveAll(all)
    }

    func updateRule(_ rule: AlertRule) {
        var all = loadAll()
        if let idx = all.firstIndex(where: { $0.id == rule.id }) {
            all[idx] = rule
        }
        saveAll(all)
    }

    func removeRule(id: UUID) {
        var all = loadAll()
        all.removeAll { $0.id == id }
        saveAll(all)
    }

    func alertState(for panelID: UUID) -> AlertState? {
        let panelRules = rules(for: panelID).filter(\.enabled)
        guard !panelRules.isEmpty else { return nil }
        if panelRules.contains(where: { $0.state == .alerting }) { return .alerting }
        if panelRules.contains(where: { $0.state == .noData }) { return .noData }
        return .ok
    }

    // MARK: - Evaluation

    private func evaluateAll(dataProvider: @escaping () -> Double?) {
        var all = loadAll()
        for i in all.indices where all[i].enabled {
            let value = dataProvider()
            all[i].lastEvaluated = Date()

            guard let val = value else {
                all[i].state = .noData
                continue
            }

            let triggered: Bool
            switch all[i].condition {
            case .above:
                triggered = val > all[i].threshold
            case .below:
                triggered = val < all[i].threshold
            case .outsideRange:
                let upper = all[i].thresholdUpper ?? all[i].threshold
                triggered = val < all[i].threshold || val > upper
            }

            if triggered {
                if all[i].state != .alerting {
                    all[i].state = .alerting
                    all[i].lastTriggered = Date()
                    if all[i].notifyViaSystem {
                        sendNotification(rule: all[i], value: val)
                    }
                }
            } else {
                all[i].state = .ok
            }
        }
        saveAll(all)
    }

    private func sendNotification(rule: AlertRule, value: Double) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "TokiMonitor Alert"
            content.body = "\(rule.name): \(String(format: "%.2f", value)) \(rule.condition.displayName) \(String(format: "%.2f", rule.threshold))"
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: rule.id.uuidString,
                content: content,
                trigger: nil
            )
            center.add(request)
        }
    }

    // MARK: - Persistence

    private func loadAll() -> [AlertRule] {
        guard let data = UserDefaults.standard.data(forKey: Self.storeKey),
              let items = try? JSONDecoder().decode([AlertRule].self, from: data)
        else { return [] }
        return items
    }

    private func saveAll(_ items: [AlertRule]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: Self.storeKey)
    }
}
