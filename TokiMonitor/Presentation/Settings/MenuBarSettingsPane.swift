import SwiftUI

struct MenuBarSettingsPane: View {
    @Bindable var settings: AppSettings
    private let availableThemes = AnimationTheme.discoverAll()
    @State private var expandedWidgetIds: Set<String> = []

    var body: some View {
        Form {
            Section(L.menuBar.displayMode) {
                Picker(L.menuBar.mode, selection: $settings.providerDisplayMode) {
                    ForEach(ProviderDisplayMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if shouldShowTokenUnit {
                    Picker(L.menuBar.unit, selection: $settings.tokenUnit) {
                        ForEach(TokenUnit.allCases, id: \.self) { unit in
                            Text(unit.displayName).tag(unit)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Picker(L.menuBar.sparklineTimeRange, selection: Binding(
                    get: { settings.graphTimeRange },
                    set: {
                        settings.graphTimeRange = $0
                        settings.pendingPopupRequest = .mostActive
                    }
                )) {
                    ForEach(GraphTimeRange.allCases, id: \.self) { range in
                        Text(range.displayName).tag(range)
                    }
                }
                .pickerStyle(.segmented)

                Picker(L.menuBar.sleepDelay, selection: $settings.sleepDelay) {
                    ForEach(SleepDelay.allCases, id: \.self) { delay in
                        Text(delay.displayName).tag(delay)
                    }
                }
                .pickerStyle(.segmented)
            }

            if settings.providerDisplayMode == .aggregated {
                aggregatedSection
                widgetOrderSection
            } else {
                perProviderSections
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Aggregated Mode

    private var aggregatedSection: some View {
        Section(L.menuBar.animation) {
            animationControls(
                style: $settings.animationStyle,
                showRateText: $settings.showRateText,
                textPosition: $settings.textPosition
            )

            HStack {
                Text(L.menuBar.iconColor)
                Spacer()
                colorPickerMenu(
                    currentColor: settings.aggregatedColorName,
                    defaultLabel: L.menuBar.defaultWhite
                ) { color in
                    settings.aggregatedColorName = color
                }
            }
        }
    }

    // MARK: - Per-Provider Mode

    private var perProviderSections: some View {
        ForEach(enabledProviders) { provider in
            Section {
                let ps = settings.effectiveSettings(for: provider.id)

                animationControls(
                    style: Binding(
                        get: { ps.animationStyle ?? settings.animationStyle },
                        set: { newVal in
                            var updated = ps
                            updated.animationStyle = newVal == settings.animationStyle ? nil : newVal
                            settings.providerSettingsMap[provider.id] = updated
                        }
                    ),
                    showRateText: $settings.showRateText,
                    textPosition: $settings.textPosition,
                    providerId: provider.id
                )

                HStack {
                    Text(L.provider.color)
                    Spacer()
                    colorPickerMenu(
                        currentColor: ps.customColorName,
                        defaultLabel: L.provider.defaultColor(provider.colorName)
                    ) { color in
                        var updated = ps
                        updated.customColorName = color
                        settings.providerSettingsMap[provider.id] = updated
                    }
                }

            } header: {
                Label(provider.name, systemImage: provider.icon)
                    .foregroundStyle(provider.color)
            }

            // Per-provider widget order
            providerWidgetOrderSection(for: provider)
        }
    }

    // MARK: - Shared Animation Controls

    @ViewBuilder
    private func animationControls(
        style: Binding<AnimationStyle>,
        showRateText: Binding<Bool>,
        textPosition: Binding<TextPosition>,
        providerId: String? = nil
    ) -> some View {
        Picker(L.menuBar.style, selection: style) {
            Text(L.menuBar.character).tag(AnimationStyle.character)
            Text(L.menuBar.numeric).tag(AnimationStyle.numeric)
            Text(L.menuBar.graph).tag(AnimationStyle.sparkline)
        }
        .pickerStyle(.segmented)

        if style.wrappedValue == .character {
            Picker(L.tr("캐릭터", "Character"), selection: $settings.animationThemeId) {
                ForEach(availableThemes, id: \.config.id) { theme in
                    Text(theme.config.localizedName).tag(theme.config.id)
                }
            }

            Toggle(L.menuBar.showRateText, isOn: showRateText)

            if showRateText.wrappedValue {
                Picker(L.menuBar.textPosition, selection: textPosition) {
                    ForEach(TextPosition.allCases, id: \.self) { pos in
                        Text(pos.displayName).tag(pos)
                    }
                }
                .pickerStyle(.segmented)
            }

            // HP Bar source
            hpBarPicker(providerId: providerId)
        }
    }

    @ViewBuilder
    private func hpBarPicker(providerId: String?) -> some View {
        let enabledProviders = Set(
            ProviderRegistry.configurableProviders
                .filter { settings.effectiveSettings(for: $0.id).enabled }
                .map(\.id)
        )

        let options: [HPBarSource] = {
            if let pid = providerId {
                // Per-provider mode: only sources for this provider
                return [.none] + HPBarSource.allCases.filter { $0.providerId == pid }
            } else {
                // Aggregated mode: sources for all enabled providers
                return HPBarSource.allCases.filter { source in
                    source == .none || enabledProviders.contains(source.providerId ?? "")
                }
            }
        }()

        if providerId != nil {
            let ps = settings.effectiveSettings(for: providerId!)
            Picker(L.tr("HP 바", "HP Bar"), selection: Binding(
                get: { ps.hpBarSource ?? settings.hpBarSource },
                set: { newVal in
                    var updated = ps
                    updated.hpBarSource = newVal == settings.hpBarSource ? nil : newVal
                    settings.providerSettingsMap[providerId!] = updated
                }
            )) {
                ForEach(options, id: \.self) { source in
                    Text(source.displayName).tag(source)
                }
            }
        } else {
            Picker(L.tr("HP 바", "HP Bar"), selection: $settings.hpBarSource) {
                ForEach(options, id: \.self) { source in
                    Text(source.displayName).tag(source)
                }
            }
        }
    }

    // MARK: - Helpers

    // MARK: - Widget Order

    private var widgetOrderSection: some View {
        Section(L.menuBar.widgetOrder) {
            let items = settings.resolvedWidgetOrder()
            ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                let key = expansionKey(global: true, providerId: nil, widgetId: item.id)
                widgetRow(item: item, index: idx, total: items.count, global: true, providerId: nil)
                if widgetHasSettings(item.id), expandedWidgetIds.contains(key) {
                    widgetSettingsView(item.id)
                        .padding(.leading, DS.sm)
                }
            }
        }
    }

    private func providerWidgetOrderSection(for provider: ProviderInfo) -> some View {
        Section(L.menuBar.widgetOrder) {
            let items = settings.resolvedProviderWidgetOrder(for: provider.id)
            ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                let key = expansionKey(global: false, providerId: provider.id, widgetId: item.id)
                widgetRow(item: item, index: idx, total: items.count, global: false, providerId: provider.id)
                if widgetHasSettings(item.id), expandedWidgetIds.contains(key) {
                    widgetSettingsView(item.id)
                        .padding(.leading, DS.sm)
                }
            }
        }
    }

    // MARK: - Widget Row Helpers

    private func widgetRow(
        item: MenuWidgetItem,
        index: Int,
        total: Int,
        global: Bool,
        providerId: String?
    ) -> some View {
        HStack(spacing: DS.sm) {
            Image(systemName: item.visible ? "eye" : "eye.slash")
                .foregroundStyle(item.visible ? .primary : .tertiary)
                .frame(width: 20)
                .onTapGesture {
                    if global {
                        toggleWidgetVisibility(item.id)
                    } else if let providerId {
                        toggleProviderWidgetVisibility(providerId: providerId, widgetId: item.id)
                    }
                }

            if widgetHasSettings(item.id) {
                Button {
                    let key = expansionKey(global: global, providerId: providerId, widgetId: item.id)
                    if expandedWidgetIds.contains(key) {
                        expandedWidgetIds.remove(key)
                    } else {
                        expandedWidgetIds.insert(key)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(widgetDisplayName(item.id))
                            .foregroundStyle(item.visible ? .primary : .tertiary)
                        Image(systemName: expandedWidgetIds.contains(expansionKey(global: global, providerId: providerId, widgetId: item.id)) ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Text(widgetDisplayName(item.id))
                    .foregroundStyle(item.visible ? .primary : .tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()

            Button {
                if global {
                    moveWidget(at: index, direction: -1, global: true)
                } else if let providerId {
                    moveProviderWidget(providerId: providerId, at: index, direction: -1)
                }
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .disabled(index == 0)

            Button {
                if global {
                    moveWidget(at: index, direction: 1, global: true)
                } else if let providerId {
                    moveProviderWidget(providerId: providerId, at: index, direction: 1)
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .disabled(index == total - 1)
        }
    }

    private func widgetHasSettings(_ id: String) -> Bool {
        id == MenuWidgetItem.claudeUsageId || id == MenuWidgetItem.codexUsageId
    }

    @ViewBuilder
    private func widgetSettingsView(_ id: String) -> some View {
        Group {
            if id == MenuWidgetItem.claudeUsageId {
                indentedRow(Toggle(
                    ClaudeUsageBucketOption.fiveHour.displayName,
                    isOn: Binding(
                        get: { settings.isClaudeUsageBucketVisible(.fiveHour) },
                        set: { settings.setClaudeUsageBucketVisible(.fiveHour, visible: $0) }
                    )
                ))
                indentedRow(Toggle(
                    ClaudeUsageBucketOption.sevenDay.displayName,
                    isOn: Binding(
                        get: { settings.isClaudeUsageBucketVisible(.sevenDay) },
                        set: { settings.setClaudeUsageBucketVisible(.sevenDay, visible: $0) }
                    )
                ))
                indentedRow(
                    Toggle(
                        ClaudeUsageBucketOption.sevenDaySonnet.displayName,
                        isOn: Binding(
                            get: { settings.isClaudeUsageBucketVisible(.sevenDaySonnet) },
                            set: { settings.setClaudeUsageBucketVisible(.sevenDaySonnet, visible: $0) }
                        )
                    )
                    .disabled(settings.claudeHasSevenDaySonnet == false)
                    .opacity(settings.claudeHasSevenDaySonnet == false ? 0.45 : 1)
                )
            } else if id == MenuWidgetItem.codexUsageId {
                indentedRow(Toggle(
                    CodexUsageWindowOption.primary.displayName,
                    isOn: Binding(
                        get: { settings.isCodexUsageWindowVisible(.primary) },
                        set: { settings.setCodexUsageWindowVisible(.primary, visible: $0) }
                    )
                ))
                indentedRow(
                    Toggle(
                        CodexUsageWindowOption.secondary.displayName,
                        isOn: Binding(
                            get: { settings.isCodexUsageWindowVisible(.secondary) },
                            set: { settings.setCodexUsageWindowVisible(.secondary, visible: $0) }
                        )
                    )
                    .disabled(settings.codexHasSecondaryWindow == false)
                    .opacity(settings.codexHasSecondaryWindow == false ? 0.45 : 1)
                )
            }
        }
    }

    private func indentedRow<Content: View>(_ content: Content) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 16)
            content
        }
    }

    private func expansionKey(global: Bool, providerId: String?, widgetId: String) -> String {
        if global { return "global:\(widgetId)" }
        return "provider:\(providerId ?? "unknown"):\(widgetId)"
    }

    private func expansionBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: { expandedWidgetIds.contains(key) },
            set: { isExpanded in
                if isExpanded {
                    expandedWidgetIds.insert(key)
                } else {
                    expandedWidgetIds.remove(key)
                }
            }
        )
    }

    private func toggleProviderWidgetVisibility(providerId: String, widgetId: String) {
        var ps = settings.effectiveSettings(for: providerId)
        var order = settings.resolvedProviderWidgetOrder(for: providerId)
        if let idx = order.firstIndex(where: { $0.id == widgetId }) {
            order[idx].visible.toggle()
            ps.widgetOrder = order
            settings.providerSettingsMap[providerId] = ps
            settings.pendingPopupRequest = .provider(providerId)
        }
    }

    private func moveWidget(at index: Int, direction: Int, global: Bool) {
        var order = settings.resolvedWidgetOrder()
        let newIndex = index + direction
        guard newIndex >= 0, newIndex < order.count else { return }
        order.swapAt(index, newIndex)
        settings.widgetOrder = order
        settings.pendingPopupRequest = .mostActive
    }

    private func moveProviderWidget(providerId: String, at index: Int, direction: Int) {
        var ps = settings.effectiveSettings(for: providerId)
        var order = settings.resolvedProviderWidgetOrder(for: providerId)
        let newIndex = index + direction
        guard newIndex >= 0, newIndex < order.count else { return }
        order.swapAt(index, newIndex)
        ps.widgetOrder = order
        settings.providerSettingsMap[providerId] = ps
        settings.pendingPopupRequest = .provider(providerId)
    }

    private func toggleWidgetVisibility(_ id: String) {
        var order = settings.resolvedWidgetOrder()
        if let idx = order.firstIndex(where: { $0.id == id }) {
            order[idx].visible.toggle()
            settings.widgetOrder = order
            settings.pendingPopupRequest = .mostActive
        }
    }

    private func widgetDisplayName(_ id: String) -> String {
        if id == MenuWidgetItem.claudeUsageId {
            return L.menuBar.claudeUsage
        }
        if id == MenuWidgetItem.codexUsageId {
            return L.tr("Codex 사용량", "Codex Usage")
        }
        return ProviderRegistry.allProviders.first { $0.id == id }?.name ?? id
    }

    private var enabledProviders: [ProviderInfo] {
        ProviderRegistry.configurableProviders.filter {
            settings.effectiveSettings(for: $0.id).enabled
        }
    }

    private var shouldShowTokenUnit: Bool {
        settings.animationStyle == .numeric ||
        (settings.animationStyle == .character && settings.showRateText)
    }

    private func colorPickerMenu(
        currentColor: String?,
        defaultLabel: String,
        onSelect: @escaping (String?) -> Void
    ) -> some View {
        Menu {
            Button(action: { onSelect(nil) }) {
                HStack {
                    Text(defaultLabel)
                    if currentColor == nil {
                        Image(systemName: "checkmark")
                    }
                }
            }
            Divider()
            ForEach(ProviderInfo.availableColors, id: \.name) { color in
                Button(action: { onSelect(color.name) }) {
                    HStack {
                        Circle()
                            .fill(ProviderInfo.colorFromName(color.name))
                            .frame(width: 10, height: 10)
                        Text(color.displayName)
                        if currentColor == color.name {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(currentColor.map { ProviderInfo.colorFromName($0) } ?? .white)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(.secondary.opacity(0.3), lineWidth: 1))
                Text(colorDisplayName(currentColor, defaultLabel: defaultLabel))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func colorDisplayName(_ currentColor: String?, defaultLabel: String) -> String {
        if let colorName = currentColor {
            return ProviderInfo.availableColors.first { $0.name == colorName }?.displayName ?? colorName
        }
        return defaultLabel
    }
}
