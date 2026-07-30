import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ImportFolderDropTarget: View {
    let onPreparedSources: (ImportSourcePreparation) -> Void
    let onDropFailure: () -> Void

    var body: some View {
        ZStack {
            FolderDropInteraction(
                onPreparedSources: onPreparedSources,
                onDropFailure: onDropFailure
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 8) {
                Image(systemName: "folder.badge.plus")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 44, height: 44)
                    .background(.tint.opacity(0.12), in: Circle())

                Text("import.dropTarget.title")
                    .font(.headline)

                Text("import.dropTarget.description")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(16)
            .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, minHeight: 136)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("import.dropTarget.title"))
        .accessibilityHint(Text("import.dropTarget.description"))
        .accessibilityIdentifier("import.dropTarget")
    }
}

private struct FolderDropInteraction: UIViewRepresentable {
    let onPreparedSources: (ImportSourcePreparation) -> Void
    let onDropFailure: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onPreparedSources: onPreparedSources,
            onDropFailure: onDropFailure
        )
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.addInteraction(UIDropInteraction(delegate: context.coordinator))
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onPreparedSources = onPreparedSources
        context.coordinator.onDropFailure = onDropFailure
    }

    final class Coordinator: NSObject, UIDropInteractionDelegate {
        var onPreparedSources: (ImportSourcePreparation) -> Void
        var onDropFailure: () -> Void

        private let sourcePreparer = ImportSourcePreparer()

        init(
            onPreparedSources: @escaping (ImportSourcePreparation) -> Void,
            onDropFailure: @escaping () -> Void
        ) {
            self.onPreparedSources = onPreparedSources
            self.onDropFailure = onDropFailure
        }

        func dropInteraction(
            _ interaction: UIDropInteraction,
            canHandle session: UIDropSession
        ) -> Bool {
            session.hasItemsConforming(
                toTypeIdentifiers: [UTType.folder.identifier]
            )
        }

        func dropInteraction(
            _ interaction: UIDropInteraction,
            sessionDidUpdate session: UIDropSession
        ) -> UIDropProposal {
            UIDropProposal(operation: .copy)
        }

        func dropInteraction(
            _ interaction: UIDropInteraction,
            performDrop session: UIDropSession
        ) {
            let providers = session.items.enumerated().compactMap { index, item in
                item.itemProvider.hasItemConformingToTypeIdentifier(
                    UTType.folder.identifier
                ) ? (index, item.itemProvider) : nil
            }
            guard !providers.isEmpty else {
                onDropFailure()
                return
            }

            let collector = FolderDropResultCollector()
            let group = DispatchGroup()
            let preparer = sourcePreparer

            for (index, provider) in providers {
                group.enter()
                provider.loadInPlaceFileRepresentation(
                    forTypeIdentifier: UTType.folder.identifier
                ) { [preparer] sourceURL, isInPlace, _ in
                    defer { group.leave() }

                    guard let sourceURL, isInPlace else {
                        collector.recordFailure(at: index)
                        return
                    }

                    let preparation = preparer.prepare([sourceURL])
                    guard let source = preparation.sources.first else {
                        collector.recordFailure(at: index)
                        return
                    }

                    collector.record(source, at: index)
                }
            }

            group.notify(queue: .main) { [weak self] in
                let preparation = collector.preparation()
                guard !preparation.sources.isEmpty else {
                    self?.onDropFailure()
                    return
                }

                self?.onPreparedSources(preparation)
            }
        }
    }
}

private final class FolderDropResultCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var sources: [Int: ImportSourceDescriptor] = [:]
    private var failedIndexes = Set<Int>()

    func record(_ source: ImportSourceDescriptor, at index: Int) {
        lock.lock()
        sources[index] = source
        lock.unlock()
    }

    func recordFailure(at index: Int) {
        lock.lock()
        failedIndexes.insert(index)
        lock.unlock()
    }

    func preparation() -> ImportSourcePreparation {
        lock.lock()
        defer { lock.unlock() }

        return ImportSourcePreparation(
            sources: sources.keys.sorted().compactMap { sources[$0] },
            rejectedDisplayNames: failedIndexes.sorted().map { "drop-\($0)" }
        )
    }
}
