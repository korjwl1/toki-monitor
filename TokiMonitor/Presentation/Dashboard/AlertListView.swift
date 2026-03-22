import SwiftUI

/// Alert rules list view accessible from sidebar.
struct AlertListView: View {
    @Bindable var viewModel: DashboardViewModel
    @State private var showAddAlert = false
    @State private var editingRule: AlertRule?

    var body: some View {
        VStack(spacing: 0) {
            DetailHeaderView(title: L.dash.alerts, icon: "bell") {
                Button {
                    showAddAlert = true
                } label: {
                    Label(L.dash.addAlert, systemImage: "plus")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
            }

            let rules = viewModel.alertManager.allRules()
            if rules.isEmpty {
                ContentUnavailableView(
                    L.tr("알림 규칙이 없습니다", "No alert rules"),
                    systemImage: "bell.slash",
                    description: Text(L.tr("패널에 알림 규칙을 추가하여 임계값 초과 시 알림을 받으세요", "Add alert rules to panels to get notified when thresholds are exceeded"))
                )
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(rules) { rule in
                        alertRuleRow(rule)
                    }
                }
                .listStyle(.plain)
            }
        }
        .sheet(isPresented: $showAddAlert) {
            AlertRuleEditorSheet(viewModel: viewModel, rule: nil) { newRule in
                viewModel.alertManager.addRule(newRule)
                showAddAlert = false
            }
        }
        .sheet(item: $editingRule) { rule in
            AlertRuleEditorSheet(viewModel: viewModel, rule: rule) { updatedRule in
                viewModel.alertManager.updateRule(updatedRule)
                editingRule = nil
            }
        }
    }

    private func alertRuleRow(_ rule: AlertRule) -> some View {
        HStack {
            // State indicator
            Image(systemName: rule.state.iconName)
                .foregroundStyle(alertStateColor(rule.state))
                .font(.caption)

            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name)
                    .font(.subheadline.bold())
                HStack(spacing: 4) {
                    Text(rule.condition.displayName)
                    Text(String(format: "%.2f", rule.threshold))
                    if let upper = rule.thresholdUpper {
                        Text("- \(String(format: "%.2f", upper))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let lastEval = rule.lastEvaluated {
                    Text(L.tr("마지막 평가: ", "Last evaluated: ") + lastEval.formatted(.relative(presentation: .named)))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { newValue in
                    var updated = rule
                    updated.enabled = newValue
                    viewModel.alertManager.updateRule(updated)
                }
            ))
            .labelsHidden()
            .controlSize(.small)

            Button {
                editingRule = rule
            } label: {
                Image(systemName: "pencil")
                    .font(.caption)
            }
            .buttonStyle(.plain)

            Button(role: .destructive) {
                viewModel.alertManager.removeRule(id: rule.id)
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    private func alertStateColor(_ state: AlertState) -> Color {
        switch state {
        case .ok: .green
        case .alerting: .red
        case .noData: .secondary
        }
    }
}

// MARK: - Alert Rule Editor Sheet

struct AlertRuleEditorSheet: View {
    @Bindable var viewModel: DashboardViewModel
    @State private var rule: AlertRule
    let onSave: (AlertRule) -> Void
    @Environment(\.dismiss) private var dismiss

    init(viewModel: DashboardViewModel, rule: AlertRule?, onSave: @escaping (AlertRule) -> Void) {
        self.viewModel = viewModel
        let defaultPanelID = viewModel.dashboardConfig.panels.first?.id ?? UUID()
        _rule = State(initialValue: rule ?? AlertRule(
            panelID: defaultPanelID,
            name: "",
            condition: .above,
            threshold: 100
        ))
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(L.dash.addAlert)
                .font(.headline)

            // Name
            HStack {
                Text(L.dash.alertName)
                    .font(.caption)
                    .frame(width: 80, alignment: .leading)
                TextField(L.dash.alertName, text: $rule.name)
                    .textFieldStyle(.roundedBorder)
            }

            // Panel
            HStack {
                Text(L.tr("패널", "Panel"))
                    .font(.caption)
                    .frame(width: 80, alignment: .leading)
                Picker("", selection: $rule.panelID) {
                    ForEach(viewModel.dashboardConfig.panels.filter { $0.panelType != .rowPanel }) { panel in
                        Text(panel.title).tag(panel.id)
                    }
                }
                .pickerStyle(.menu)
            }

            // Condition
            HStack {
                Text(L.dash.condition)
                    .font(.caption)
                    .frame(width: 80, alignment: .leading)
                Picker("", selection: $rule.condition) {
                    ForEach(AlertCondition.allCases, id: \.rawValue) { condition in
                        Text(condition.displayName).tag(condition)
                    }
                }
                .pickerStyle(.segmented)
            }

            // Threshold
            HStack {
                Text(L.dash.threshold)
                    .font(.caption)
                    .frame(width: 80, alignment: .leading)
                TextField(L.dash.threshold, value: $rule.threshold, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)

                if rule.condition == .outsideRange {
                    Text("-")
                    TextField(L.tr("상한", "Upper"), value: Binding(
                        get: { rule.thresholdUpper ?? rule.threshold },
                        set: { rule.thresholdUpper = $0 }
                    ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                }
            }

            // Notify
            Toggle(L.tr("시스템 알림", "System notification"), isOn: $rule.notifyViaSystem)

            HStack {
                Button(L.dash.cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(L.tr("저장", "Save")) {
                    onSave(rule)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(rule.name.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
