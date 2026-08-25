import SwiftUI

/// What a panel drawn by a newer build looks like here.
///
/// The alternative — dropping the panel because its `panelType` has no case —
/// costs the user a panel they cannot rebuild, and does it silently: the
/// dashboard just comes back one panel shorter. So the panel stays, its
/// configuration stays byte-for-byte (`PanelConfig.unknownPanelTypeRaw`), and
/// the space it occupies says what happened instead of pretending to be data
/// (contract R5 → `dashboard-json.md` C1).
///
/// It names the type it could not draw. "Cannot display this" alone leaves the
/// reader with nothing to search for or report.
struct UnknownPanelView: View {
    let panel: PanelConfig

    var body: some View {
        ViewThatFits(in: .vertical) {
            full
            minimal
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, DS.sm)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            L.tr("\(panel.title): 이 버전이 표시할 수 없는 패널 종류 \(panel.panelTypeLabel). 설정은 그대로 보존됩니다.",
                 "\(panel.title): panel type \(panel.panelTypeLabel) cannot be displayed by this version. Its configuration is preserved.")
        )
    }

    private var full: some View {
        VStack(spacing: DS.xs) {
            Image(systemName: "questionmark.square.dashed")
                .font(.system(size: 20))
                .foregroundStyle(Color.primary.opacity(0.55))
            Text(L.tr("이 버전으로는 표시할 수 없습니다",
                      "This version cannot display it"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.72))
            Text(panel.panelTypeLabel)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.primary.opacity(0.72))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(L.tr("설정은 그대로 보존되며, 저장해도 지워지지 않습니다.",
                      "The configuration is kept and survives a save."))
                .font(.system(size: 10))
                .foregroundStyle(Color.primary.opacity(0.72))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var minimal: some View {
        HStack(spacing: DS.xs) {
            Image(systemName: "questionmark.square.dashed")
                .font(.system(size: 11))
            Text(panel.panelTypeLabel)
                .font(.system(size: 10, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(Color.primary.opacity(0.72))
    }
}
