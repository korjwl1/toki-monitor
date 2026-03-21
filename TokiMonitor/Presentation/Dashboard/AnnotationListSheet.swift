import SwiftUI

/// Annotation management sheet for adding/viewing/removing annotations.
struct AnnotationListSheet: View {
    @Bindable var viewModel: DashboardViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var newAnnotationText = ""
    @State private var newAnnotationDate = Date()
    @State private var newAnnotationTags = ""
    @State private var newAnnotationColor = "#FF6600"
    @State private var showAddForm = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(L.dash.annotations)
                    .font(.headline)
                Spacer()
                Button {
                    showAddForm.toggle()
                } label: {
                    Label(L.dash.addAnnotation, systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.plain)

                Button(L.dash.done) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.bar)

            Divider()

            // Add form
            if showAddForm {
                addAnnotationForm
                Divider()
            }

            // Annotation list
            if viewModel.annotations.isEmpty {
                ContentUnavailableView(
                    L.tr("주석이 없습니다", "No annotations"),
                    systemImage: "note.text"
                )
            } else {
                List {
                    ForEach(viewModel.annotations) { annotation in
                        HStack {
                            Circle()
                                .fill(Color.orange)
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(annotation.text)
                                    .font(.caption)
                                HStack {
                                    Text(annotation.timestamp, style: .date)
                                    Text(annotation.timestamp, style: .time)
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                if !annotation.tags.isEmpty {
                                    HStack(spacing: 4) {
                                        ForEach(annotation.tags, id: \.self) { tag in
                                            Text(tag)
                                                .font(.system(size: 9))
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 1)
                                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                                        }
                                    }
                                }
                            }
                            Spacer()
                            Button(role: .destructive) {
                                viewModel.removeAnnotation(id: annotation.id)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 480, height: 400)
    }

    private var addAnnotationForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L.dash.annotationText)
                    .font(.caption)
                    .frame(width: 60, alignment: .leading)
                TextField(L.dash.annotationText, text: $newAnnotationText)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Text(L.tr("날짜", "Date"))
                    .font(.caption)
                    .frame(width: 60, alignment: .leading)
                DatePicker("", selection: $newAnnotationDate)
                    .labelsHidden()
            }
            HStack {
                Text(L.dash.tags)
                    .font(.caption)
                    .frame(width: 60, alignment: .leading)
                TextField(L.tr("태그 (쉼표 구분)", "Tags (comma separated)"), text: $newAnnotationTags)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
            }
            HStack {
                Spacer()
                Button(L.dash.add) {
                    let tags = newAnnotationTags
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    viewModel.addAnnotation(
                        timestamp: newAnnotationDate,
                        text: newAnnotationText,
                        tags: tags,
                        colorHex: newAnnotationColor
                    )
                    newAnnotationText = ""
                    newAnnotationTags = ""
                    showAddForm = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(newAnnotationText.isEmpty)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.3))
    }
}
