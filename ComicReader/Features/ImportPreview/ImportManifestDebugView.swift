import Foundation
import SwiftUI

struct ImportManifestDebugView: View {
    let manifests: [ImportManifest]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ContentUnavailableView {
                    Label(
                        "import.preview.title",
                        systemImage: "doc.text.magnifyingglass"
                    )
                } description: {
                    Text("import.preview.debugNote")
                }

                ForEach(manifests.indices, id: \.self) { index in
                    manifestCard(
                        manifests[index],
                        index: index
                    )
                }
            }
            .frame(maxWidth: 720)
            .padding()
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("import.preview")
    }

    private func manifestCard(
        _ manifest: ImportManifest,
        index: Int
    ) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                summary(for: manifest)

                Divider()

                ForEach(manifest.chapters.indices, id: \.self) { chapterIndex in
                    chapterRow(
                        manifest.chapters[chapterIndex],
                        in: manifest,
                        index: chapterIndex
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(manifest.sourceRootName)
        }
        .accessibilityIdentifier("import.preview.comic.\(index)")
    }

    private func summary(for manifest: ImportManifest) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(
                String.localizedStringWithFormat(
                    String(localized: "import.preview.summary"),
                    manifest.collections.count,
                    manifest.chapters.count,
                    manifest.chapterPageCount,
                    manifest.issues.count
                )
            )

            Text(
                String.localizedStringWithFormat(
                    String(localized: "import.preview.cover"),
                    manifest.coverPage?.originalFileName
                        ?? String(localized: "import.preview.noCover")
                )
            )

            Text(
                String.localizedStringWithFormat(
                    String(localized: "import.preview.space"),
                    ByteCountFormatter.string(
                        fromByteCount: manifest.spaceEstimate.requiredAvailableBytes,
                        countStyle: .file
                    )
                )
            )
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    private func chapterRow(
        _ chapter: ImportChapterCandidate,
        in manifest: ImportManifest,
        index: Int
    ) -> some View {
        let pages = manifest.pages(in: chapter)

        return DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(pages) { page in
                    Label {
                        Text(page.sourceRelativePath.stringValue)
                            .textSelection(.enabled)
                    } icon: {
                        Image(
                            systemName: page.state == .readable
                                ? "photo"
                                : "exclamationmark.triangle"
                        )
                    }
                    .foregroundStyle(
                        page.state == .readable
                            ? Color.primary
                            : Color.orange
                    )
                }
            }
            .padding(.top, 6)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(chapter.originalName)
                Text(
                    String.localizedStringWithFormat(
                        String(localized: "import.preview.chapterPages"),
                        pages.count
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("import.preview.chapter.\(index)")
    }
}
