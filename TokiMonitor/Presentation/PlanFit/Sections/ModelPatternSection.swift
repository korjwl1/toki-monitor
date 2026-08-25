import SwiftUI

// MARK: - Model patterns (T056, T057 / contract W2, FR-026…FR-028)
//
// The obvious layout for this section — two provider columns, each with a list
// of models and a percentage — would be a lie about one of them.
//
// **Claude splits part of its weekly limit by model.** `seven_day_opus` and
// `seven_day_sonnet` are separate windows with their own utilisation, so
// "Opus ran at p95 88%" is an observation about a limit that exists.
//
// **Codex has no model-scoped windows at all.** Every Codex window carries
// `limit_id="codex"`, verified against the real database. There is no per-model
// utilisation to report, and printing one in the same shape as Claude's would
// promise data that does not exist.
//
// So the block for each provider has two halves that are drawn differently and
// labelled separately: limit rows, which only a provider with model-scoped
// windows has, and token-event rows, which both have. Every row carries the
// source it came from as a symbol AND a word, the legend at the foot of the
// section says what each source can and cannot answer, and a provider with no
// model-scoped windows states that outright — an empty half would otherwise
// read as missing data rather than as a fact about the provider.

struct ModelPatternSection: View {
    let model: ModelPatternModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.md) {
            PlanFitSectionHeader(
                title: L.tr("모델별 패턴", "Model patterns"),
                subtitle: L.tr(
                    "모델별 분해는 두 공급자에서 서로 다른 곳에서 옵니다. 어느 쪽에서 왔는지가 줄마다 붙어 있습니다.",
                    "The per-model breakdown comes from a different place on each side. Every row says which."
                )
            )
            Text(model.periodNote)
                .font(.system(size: PlanFitType.caption))
                .foregroundStyle(PlanFitInk.support)

            if let unavailable = model.unavailableNote {
                PlanFitMark(tone: .neutral, text: unavailable, size: PlanFitType.caption)
            }

            ForEach(model.blocks) { block in
                ModelProviderBlock(block: block)
            }

            Divider().opacity(0.4)
            ModelSourceLegend()
        }
        .planFitCard(.section)
    }
}

// MARK: - One provider

struct ModelProviderBlock: View {
    let block: ModelPatternModel.ProviderBlock

    var body: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            HStack(alignment: .firstTextBaseline, spacing: DS.sm) {
                Text(block.title)
                    .font(.system(size: PlanFitType.body, weight: .semibold))
                    .foregroundStyle(PlanFitInk.strong)
                Spacer(minLength: 0)
                Text(block.sourceNote)
                    .font(.system(size: PlanFitType.tiny))
                    .foregroundStyle(PlanFitInk.faint)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // T057. The sentence a provider without model-scoped windows needs,
            // said where its absence would otherwise be read as a gap.
            if let asymmetry = block.asymmetryNote {
                Text(asymmetry)
                    .font(.system(size: PlanFitType.caption))
                    .foregroundStyle(PlanFitInk.support)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !block.limitRows.isEmpty {
                group(
                    title: L.tr("모델별 한도의 소진율", "Utilisation of the model's own limit"),
                    rows: block.limitRows
                )
            }
            if !block.usageRows.isEmpty {
                group(
                    title: L.tr("모델별 사용 비중", "Share of use by model"),
                    rows: block.usageRows
                )
            }
            if let empty = block.emptyNote {
                Text(empty)
                    .font(.system(size: PlanFitType.caption))
                    .foregroundStyle(PlanFitInk.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .planFitCard(.inner)
    }

    private func group(title: String, rows: [ModelPatternModel.Row]) -> some View {
        VStack(alignment: .leading, spacing: DS.xs) {
            Text(title)
                .font(.system(size: PlanFitType.caption, weight: .medium))
                .foregroundStyle(PlanFitInk.support)
            ForEach(rows) { row in
                ModelPatternRow(row: row)
            }
        }
    }
}

// MARK: - One model

struct ModelPatternRow: View {
    let row: ModelPatternModel.Row

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: DS.sm) {
                Text(row.model)
                    .font(.system(size: PlanFitType.body, weight: .medium))
                    .foregroundStyle(PlanFitInk.strong)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: DS.xs)
                Text(row.detail)
                    .font(.system(size: PlanFitType.caption))
                    .foregroundStyle(PlanFitInk.support)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let change = row.changeText {
                    Text(change)
                        .font(.system(size: PlanFitType.tiny))
                        .foregroundStyle(PlanFitInk.faint)
                }
                ProvenanceTag(provenance: row.provenance)
            }
            HStack(spacing: DS.xs) {
                SourceTag(source: row.source)
                // A share of the provider's own tokens. Limit rows get no bar:
                // a utilisation is not a share of anything, and drawing them
                // the same way is the confusion this section exists to avoid.
                if let share = row.sharePct {
                    ShareBar(fraction: min(1, max(0, share / 100)))
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.model), \(row.detail), \(row.source.label)")
    }
}

// MARK: - Source

/// Where one row came from — symbol, word, and only then any colour.
struct SourceTag: View {
    let source: ModelBreakdownSource

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: source.symbolName)
                .font(.system(size: PlanFitType.tiny, weight: .semibold))
            Text(source.label)
                .font(.system(size: PlanFitType.tiny))
        }
        .foregroundStyle(PlanFitInk.faint)
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(source.label)
        .accessibilityHint(source.explanation)
    }
}

/// What each source can answer, once, at the foot of the section.
struct ModelSourceLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: DS.xs) {
            ForEach(ModelBreakdownSource.allCases, id: \.self) { source in
                HStack(alignment: .firstTextBaseline, spacing: DS.xs) {
                    SourceTag(source: source)
                    Text(source.explanation)
                        .font(.system(size: PlanFitType.tiny))
                        .foregroundStyle(PlanFitInk.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Share

/// A share of the provider's own tokens. Never drawn against the other
/// provider's — the two denominators are different accounts of different work.
struct ShareBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 3)
                Capsule()
                    .fill(Color.accentColor.opacity(0.5))
                    .frame(width: max(1, geometry.size.width * fraction), height: 3)
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}
