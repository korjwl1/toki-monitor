import SwiftUI

/// Responsive dashboard grid view.
/// Fills the available window space — panels resize dynamically with the window.
struct CustomDashboardView: View {
    @Bindable var viewModel: DashboardViewModel
    var onEditPanel: ((PanelConfig) -> Void)?
    var onInspectPanel: ((PanelConfig) -> Void)?


    var body: some View {
        GeometryReader { geometry in
            let containerWidth = geometry.size.width - (DS.Dashboard.gridPadding * 2)
            let containerHeight = geometry.size.height - (DS.Dashboard.gridPadding * 2)
            let panels = viewModel.visiblePanels
            // Adaptive row height: fills the viewport when the grid fits
            // (preserves the default dashboard's spacious layout) but pins
            // at `defaultRowHeight` once panels exceed the viewport, at
            // which point the surrounding ScrollView takes over.
            let rowHeight = DashboardGridLayout.adaptiveRowHeight(
                for: panels,
                containerHeight: containerHeight
            )

            // Precompute each panel's grid frame so `DashboardCustomLayout`
            // (and the edit-mode overlay) share a single source of truth.
            let framesByID: [UUID: CGRect] = Dictionary(
                uniqueKeysWithValues: panels.map { panel in
                    (
                        panel.id,
                        DashboardGridLayout.frame(
                            for: panel.gridPosition,
                            in: containerWidth,
                            rowHeight: rowHeight
                        )
                    )
                }
            )
            let totalHeight = DashboardGridLayout.totalHeight(for: panels, rowHeight: rowHeight)

            ScrollView(.vertical, showsIndicators: true) {
                ZStack(alignment: .topLeading) {
                    // Edit mode grid overlay (background grid lines)
                    if viewModel.isEditing {
                        DashboardEditOverlay(
                            containerWidth: containerWidth,
                            totalHeight: totalHeight
                        )
                    }

                    // Panels placed by `DashboardCustomLayout` via `Layout`
                    // protocol. Each subview's outer frame matches its grid
                    // cell exactly — no `.offset` / `.position` workarounds,
                    // so gesture hit-test stays bounded to the right panel.
                    DashboardCustomLayout(frames: framesByID) {
                        ForEach(panels) { panel in
                            Group {
                                if panel.panelType == .rowPanel {
                                    rowPanelView(panel: panel, containerWidth: containerWidth)
                                } else {
                                    panelView(for: panel, containerWidth: containerWidth)
                                        .panelDrag(
                                            panelID: panel.id,
                                            containerWidth: containerWidth,
                                            rowHeight: rowHeight,
                                            isEditing: viewModel.isEditing,
                                            viewModel: viewModel
                                        )
                                        .panelEdgeResize(
                                            panelID: panel.id,
                                            panelType: panel.panelType,
                                            containerWidth: containerWidth,
                                            rowHeight: rowHeight,
                                            isEditing: viewModel.isEditing,
                                            viewModel: viewModel
                                        )
                                }
                            }
                            .panelID(panel.id)
                        }
                    }
                    .frame(width: containerWidth, height: totalHeight, alignment: .topLeading)
                }
                .padding(DS.Dashboard.gridPadding)
            }
        }
    }

    // MARK: - Row Panel View

    private func rowPanelView(panel: PanelConfig, containerWidth: CGFloat) -> some View {
        let isCollapsed = viewModel.collapsedRows.contains(panel.id) || panel.collapsed

        return HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.toggleRowCollapse(panelID: panel.id)
                }
            } label: {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if viewModel.isEditing {
                TextField(L.tr("행 제목", "Row title"), text: Binding(
                    get: {
                        viewModel.dashboardConfig.panels
                            .first(where: { $0.id == panel.id })?.title ?? panel.title
                    },
                    set: { newTitle in
                        if let idx = viewModel.dashboardConfig.panels.firstIndex(where: { $0.id == panel.id }) {
                            viewModel.dashboardConfig.panels[idx].title = newTitle
                            viewModel.saveDashboard()
                        }
                    }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
            } else {
                Text(panel.title)
                    .font(.system(size: 12, weight: .semibold))
            }

            VStack { Divider() }

            if viewModel.isEditing {
                Button(role: .destructive) {
                    viewModel.removePanel(id: panel.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    // MARK: - Panel Dispatch

    @ViewBuilder
    private func panelView(for panel: PanelConfig, containerWidth: CGFloat) -> some View {
        PanelContainerView(
            title: panel.title,
            isEditing: viewModel.isEditing,
            // A panel this build cannot draw has no query state worth showing:
            // whatever the fetch did, the answer on screen is "unknown type".
            // `nil` hands the whole box to the content (contract R5).
            state: panel.panelType == .unknown ? nil : panelState(for: panel),
            onDelete: { viewModel.removePanel(id: panel.id) },
            onEdit: { onEditPanel?(panel) },
            onRetry: { viewModel.fetchData() },
            // A panel with several queries can be partly answered. The state
            // says `loaded` because there IS something to draw; which query is
            // missing from it is carried separately (contract Q5).
            failedTargets: viewModel.dataState(for: panel.id).frames?.errors ?? [:],
            onInspect: onInspectPanel.map { handler in { handler(panel) } }
        ) {
            panelContent(for: panel)
        }
        // 계약 C5. One panel, as JSON, for pasting into another dashboard.
        // This is what stands in for library panels.
        .contextMenu {
            Button {
                viewModel.copyPanelJSON(panel)
            } label: {
                Label(L.tr("패널을 JSON으로 복사", "Copy Panel as JSON"),
                      systemImage: "doc.on.doc")
            }
        }
    }

    /// What this panel is showing. The fetch layer reports whether the query
    /// ran; whether it produced anything to draw is a question about THIS
    /// panel, so it is answered here and the two are combined into the state
    /// the container renders.
    private func panelState(for panel: PanelConfig) -> PanelState {
        let fetch = viewModel.dataState(for: panel.id)
        return PanelState.resolve(
            fetch,
            hasContent: Self.hasContent(fetch),
            // The toolbar's model filter hides series after the query has run,
            // so "everything is switched off" is a different answer from "the
            // query found nothing" and has a different remedy.
            hasVisibleSeries: !usesModelFilter(panel) || !viewModel.filteredModelNames.isEmpty
        )
    }

    /// Whether there is anything to draw. A datasource that serves frames and
    /// no legacy points is not empty — and neither is one that serves points
    /// under no model name.
    static func hasContent(_ state: PanelDataState) -> Bool {
        if let frames = state.frames, !frames.frames.isEmpty { return true }
        if let data = state.timeSeriesData,
           !(data.points.isEmpty && data.allModelNames.isEmpty) { return true }
        return false
    }

    /// Only the per-series panels are narrowed by the model filter. A stat card
    /// reduces every series into one number, so switching a model off does not
    /// leave it with nothing to show.
    private func usesModelFilter(_ panel: PanelConfig) -> Bool {
        switch panel.panelType {
        case .timeSeries, .barChart: return true
        default: return false
        }
    }

    /// Dispatch panel content by type. `PanelContainerView` handles the five
    /// states; `PanelContentView` owns the render, and the panel editor draws
    /// its preview through the same view so the two cannot diverge.
    @ViewBuilder
    private func panelContent(for panel: PanelConfig) -> some View {
        let state = viewModel.dataState(for: panel.id)
        PanelContentView(
            panel: panel,
            data: state.timeSeriesData,
            frames: state.frames,
            viewModel: viewModel,
            dateFormat: chartDateFormat
        )
    }

    private var chartDateFormat: Date.FormatStyle {
        PanelDateFormat.forBucket(seconds: viewModel.dashboardConfig.time.bucketSeconds)
    }
}
