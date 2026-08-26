import SwiftUI

/// What is in the document, before it is added.
///
/// Importing straight from a file picker or a paste means the first time the
/// reader learns what they took is after it is already in their list. This
/// sheet answers the four questions worth asking first — what it is called, how
/// much of it there is, and whether this build can open it at all (계약 C4).
struct DashboardImportSheet: View {
    let pending: DashboardViewModel.PendingImport
    let existingTitle: String?
    let onCancel: () -> Void
    let onAdd: (DashboardViewModel.ImportResolution) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.md) {
            Text(L.tr("대시보드 가져오기", "Import Dashboard"))
                .font(.headline)

            if let preview = pending.preview {
                summary(preview)
            }

            if let refusal = pending.refusal {
                refusalBox(refusal)
            } else if let existingTitle {
                conflictBox(existingTitle)
            }

            Divider()

            HStack {
                Text(L.tr("출처: \(pending.source)", "From: \(pending.source)"))
                    .font(.system(size: DS.fontCaption))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L.dash.cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                if pending.refusal == nil {
                    if existingTitle != nil {
                        Button(L.tr("덮어쓰기", "Replace")) { onAdd(.replaceExisting) }
                        Button(L.tr("복사본으로 추가", "Add as a copy")) { onAdd(.addAsCopy) }
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button(L.tr("가져오기", "Import")) { onAdd(.addAsCopy) }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .padding(DS.lg)
        .frame(minWidth: 420, maxWidth: 520)
    }

    // MARK: - Parts

    private func summary(_ preview: DashboardExchange.Preview) -> some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            Text(preview.title)
                .font(.system(size: DS.fontBody, weight: .semibold))

            Grid(alignment: .leading, horizontalSpacing: DS.md, verticalSpacing: DS.xs) {
                row(L.tr("패널", "Panels"), "\(preview.panelCount)")
                row(L.tr("변수", "Variables"), "\(preview.variableCount)")
                row(L.tr("요구 형식", "Requires"),
                    L.tr("스키마 v\(preview.schemaVersion) · 앱 \(preview.minAppVersion) 이상",
                         "schema v\(preview.schemaVersion) · app \(preview.minAppVersion) or newer"))
            }
            .font(.system(size: DS.fontCaption))

            if !preview.undrawablePanelTypes.isEmpty {
                // Not a refusal. The panels come in and keep their
                // configuration; they just have nothing to draw here (계약 R5).
                Text(L.tr(
                    "이 버전이 그릴 수 없는 패널 종류가 있습니다: \(preview.undrawablePanelTypes.joined(separator: ", ")). 설정은 그대로 들어오고, 자리에는 안내가 표시됩니다.",
                    "Some panel types cannot be drawn by this version: \(preview.undrawablePanelTypes.joined(separator: ", ")). They come in with their configuration intact and show a notice in their place."
                ))
                .font(.system(size: DS.fontCaption))
                .foregroundStyle(Color.primary.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }

    private func refusalBox(_ reason: String) -> some View {
        notice(symbol: "exclamationmark.triangle.fill", tint: .orange, text: reason)
    }

    private func conflictBox(_ title: String) -> some View {
        notice(
            symbol: "doc.on.doc",
            tint: .secondary,
            text: L.tr(
                "같은 식별자의 대시보드 '\(title)'이(가) 이미 있습니다. 덮어쓸지 복사본으로 추가할지 고르세요.",
                "A dashboard with the same identifier, '\(title)', already exists. Choose whether to replace it or keep both."
            )
        )
    }

    private func notice(symbol: String, tint: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: DS.xs) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text)
                .foregroundStyle(Color.primary.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: DS.fontCaption))
        .padding(DS.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}
