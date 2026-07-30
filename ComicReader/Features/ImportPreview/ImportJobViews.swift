import Foundation
import SwiftUI

struct ImportJobListView: View {
    let jobs: [ImportJobSnapshot]
    let isActive: (ImportJobID) -> Bool
    let onCancel: (ImportJobID) -> Void
    let onResume: (ImportJobID) -> Void
    let onShowReport: (ImportJobID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("import.jobs.title", systemImage: "arrow.triangle.2.circlepath")
                .font(.headline)

            ForEach(jobs) { snapshot in
                ImportJobRow(
                    snapshot: snapshot,
                    isActive: isActive(snapshot.id),
                    onCancel: { onCancel(snapshot.id) },
                    onResume: { onResume(snapshot.id) },
                    onShowReport: { onShowReport(snapshot.id) }
                )
            }
        }
        .accessibilityIdentifier("import.jobs")
    }
}

private struct ImportJobRow: View {
    let snapshot: ImportJobSnapshot
    let isActive: Bool
    let onCancel: () -> Void
    let onResume: () -> Void
    let onShowReport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: phaseSymbol)
                    .foregroundStyle(phaseColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.displayName)
                        .font(.headline)
                        .lineLimit(1)
                    Text(phaseLocalizationKey)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isActive {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            ProgressView(value: completion) {
                Text(
                    String.localizedStringWithFormat(
                        String(localized: "import.jobs.progress"),
                        snapshot.verifiedWorkItemCount,
                        snapshot.totalWorkItemCount
                    )
                )
            } currentValueLabel: {
                Text(
                    ByteCountFormatter.string(
                        fromByteCount: snapshot.verifiedByteCount,
                        countStyle: .file
                    )
                )
            }
            .tint(phaseColor)

            HStack(spacing: 10) {
                if isActive && canCancel {
                    Button("import.jobs.cancel", action: onCancel)
                        .buttonStyle(.bordered)
                }

                if snapshot.state.phase == .paused && !isActive {
                    Button("import.jobs.resume", action: onResume)
                        .buttonStyle(.borderedProminent)
                }

                if snapshot.report != nil {
                    Button("import.jobs.report", action: onShowReport)
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityIdentifier("import.job")
    }

    private var completion: Double {
        guard snapshot.totalWorkItemCount > 0 else {
            return snapshot.state.phase == .completed ? 1 : 0
        }

        return min(
            1,
            Double(snapshot.verifiedWorkItemCount)
                / Double(snapshot.totalWorkItemCount)
        )
    }

    private var canCancel: Bool {
        switch snapshot.state.phase {
        case .queued, .checkingSpace, .copying, .verifying:
            true
        case .paused, .commitPrepared, .committing, .generatingThumbnail,
                .completed, .failed:
            false
        }
    }

    private var phaseSymbol: String {
        switch snapshot.state.phase {
        case .queued, .checkingSpace, .copying, .verifying:
            "arrow.down.circle"
        case .paused:
            "pause.circle"
        case .commitPrepared, .committing, .generatingThumbnail:
            "checkmark.seal"
        case .completed:
            "checkmark.circle.fill"
        case .failed:
            "xmark.octagon.fill"
        }
    }

    private var phaseColor: Color {
        switch snapshot.state.phase {
        case .paused:
            .orange
        case .failed:
            .red
        case .completed:
            .green
        case .queued, .checkingSpace, .copying, .verifying, .commitPrepared,
                .committing, .generatingThumbnail:
            .accentColor
        }
    }

    private var phaseLocalizationKey: LocalizedStringKey {
        if isActive, !snapshot.state.isTerminal {
            return "import.jobs.copying"
        }

        switch snapshot.state.phase {
        case .queued:
            "import.jobs.queued"
        case .checkingSpace:
            "import.jobs.checkingSpace"
        case .copying:
            "import.jobs.copying"
        case .verifying:
            "import.jobs.verifying"
        case .paused:
            "import.jobs.paused"
        case .commitPrepared, .committing:
            "import.jobs.committing"
        case .generatingThumbnail:
            "import.jobs.generatingThumbnail"
        case .completed:
            "import.jobs.completed"
        case .failed:
            "import.jobs.failed"
        }
    }
}

struct ImportReportView: View {
    @Environment(\.dismiss) private var dismiss

    let snapshot: ImportJobSnapshot

    var body: some View {
        NavigationStack {
            Group {
                if let report = snapshot.report {
                    List {
                        Section("import.report.summary") {
                            LabeledContent(
                                "import.report.verifiedPages",
                                value: report.verifiedWorkItemIDs.count.formatted()
                            )
                            LabeledContent(
                                "import.report.verifiedChapters",
                                value: report.verifiedChapterIDs.count.formatted()
                            )
                            LabeledContent(
                                "import.report.scanIssues",
                                value: report.scanIssues.count.formatted()
                            )
                        }

                        Section("import.report.thumbnail") {
                            Text(thumbnailStatusLocalizationKey(report.thumbnailStatus))
                        }

                        if !report.runtimeIssues.isEmpty {
                            Section("import.report.runtimeIssues") {
                                ForEach(
                                    Array(report.runtimeIssues.enumerated()),
                                    id: \.offset
                                ) { _, issue in
                                    Text(runtimeIssueLocalizationKey(issue.code))
                                }
                            }
                        }
                    }
                } else {
                    ContentUnavailableView {
                        Label(
                            "import.report.unavailable.title",
                            systemImage: "doc.text.magnifyingglass"
                        )
                    } description: {
                        Text("import.report.unavailable.description")
                    }
                }
            }
            .navigationTitle("import.report.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func thumbnailStatusLocalizationKey(
        _ status: ImportThumbnailStatus
    ) -> LocalizedStringKey {
        switch status {
        case .notStarted:
            "import.report.thumbnailNotStarted"
        case .generated:
            "import.report.thumbnailGenerated"
        case .failed:
            "import.report.thumbnailFailed"
        }
    }

    private func runtimeIssueLocalizationKey(
        _ code: ImportRuntimeIssueCode
    ) -> LocalizedStringKey {
        switch code {
        case .copyFailed:
            "import.report.copyFailed"
        case .thumbnailFailed:
            "import.report.thumbnailFailed"
        }
    }
}
