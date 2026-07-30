import Foundation

struct ImportStorageLayout: Sendable {
    let rootURL: URL

    var importsURL: URL {
        rootURL.appendingPathComponent("Imports", isDirectory: true)
    }

    var libraryURL: URL {
        rootURL.appendingPathComponent("Library", isDirectory: true)
    }

    var thumbnailsURL: URL {
        rootURL.appendingPathComponent("Thumbnails", isDirectory: true)
    }

    func jobDirectory(for jobID: ImportJobID) -> URL {
        importsURL.appendingPathComponent(
            jobID.rawValue.uuidString.lowercased(),
            isDirectory: true
        )
    }

    func planURL(for jobID: ImportJobID) -> URL {
        jobDirectory(for: jobID).appendingPathComponent("plan.json")
    }

    func journalURL(for jobID: ImportJobID) -> URL {
        jobDirectory(for: jobID).appendingPathComponent("journal.json")
    }

    func payloadURL(for jobID: ImportJobID) -> URL {
        jobDirectory(for: jobID).appendingPathComponent(
            "payload",
            isDirectory: true
        )
    }

    func libraryURL(for comicID: ManagedComicID) -> URL {
        libraryURL.appendingPathComponent(
            comicID.rawValue.uuidString.lowercased(),
            isDirectory: true
        )
    }

    func thumbnailURL(for comicID: ManagedComicID) -> URL {
        thumbnailsURL.appendingPathComponent(
            comicID.rawValue.uuidString.lowercased() + ".jpg"
        )
    }
}

enum ImportJobStoreError: Error, Equatable, Sendable {
    case jobAlreadyExists
    case jobNotFound
    case unsupportedPlanSchema
    case unsupportedJournalSchema
    case inconsistentJournal
}

struct JSONImportJobStore: Sendable {
    let layout: ImportStorageLayout

    init(layout: ImportStorageLayout) {
        self.layout = layout
    }

    static func applicationSupportLayout(
        fileManager: FileManager = .default
    ) throws -> ImportStorageLayout {
        let applicationSupportURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        return ImportStorageLayout(
            rootURL: applicationSupportURL.appendingPathComponent(
                "ComicReader",
                isDirectory: true
            )
        )
    }

    func create(
        plan: FrozenImportPlan,
        targetComicID: ManagedComicID = ManagedComicID()
    ) throws -> ImportJobJournal {
        try ensureBaseDirectories()

        let jobDirectory = layout.jobDirectory(for: plan.id)
        guard !FileManager.default.fileExists(atPath: jobDirectory.path) else {
            throw ImportJobStoreError.jobAlreadyExists
        }

        try FileManager.default.createDirectory(
            at: jobDirectory,
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: layout.payloadURL(for: plan.id),
            withIntermediateDirectories: true
        )

        do {
            try write(plan, to: layout.planURL(for: plan.id))
            let journal = ImportJobJournal(
                plan: plan,
                targetComicID: targetComicID
            )
            try save(journal, for: plan)
            return journal
        } catch {
            try? FileManager.default.removeItem(at: jobDirectory)
            throw error
        }
    }

    func load(
        _ jobID: ImportJobID
    ) throws -> (plan: FrozenImportPlan, journal: ImportJobJournal) {
        let planURL = layout.planURL(for: jobID)
        let journalURL = layout.journalURL(for: jobID)
        guard FileManager.default.fileExists(atPath: planURL.path),
              FileManager.default.fileExists(atPath: journalURL.path) else {
            throw ImportJobStoreError.jobNotFound
        }

        let plan = try read(FrozenImportPlan.self, from: planURL)
        guard plan.schemaVersion == FrozenImportPlan.currentSchemaVersion else {
            throw ImportJobStoreError.unsupportedPlanSchema
        }

        let journal = try read(ImportJobJournal.self, from: journalURL)
        guard journal.schemaVersion == ImportJobJournal.currentSchemaVersion else {
            throw ImportJobStoreError.unsupportedJournalSchema
        }
        guard journal.isCompatible(with: plan) else {
            throw ImportJobStoreError.inconsistentJournal
        }

        return (plan, journal)
    }

    func jobIDs() throws -> [ImportJobID] {
        try ensureBaseDirectories()

        let directories = try FileManager.default.contentsOfDirectory(
            at: layout.importsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        return try directories.compactMap { directoryURL in
            let values = try directoryURL.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true,
                  let rawJobID = UUID(uuidString: directoryURL.lastPathComponent),
                  directoryURL.lastPathComponent.lowercased()
                      == rawJobID.uuidString.lowercased() else {
                return nil
            }

            return ImportJobID(rawValue: rawJobID)
        }
        .sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
    }

    func save(
        _ journal: ImportJobJournal,
        for plan: FrozenImportPlan
    ) throws {
        guard journal.isCompatible(with: plan) else {
            throw ImportJobStoreError.inconsistentJournal
        }

        try write(journal, to: layout.journalURL(for: journal.jobID))
    }

    private func ensureBaseDirectories() throws {
        for directoryURL in [
            layout.rootURL,
            layout.importsURL,
            layout.libraryURL,
            layout.thumbnailsURL,
        ] {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            try excludeFromBackup(directoryURL)
        }
    }

    private func write<Value: Encodable>(
        _ value: Value,
        to url: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    private func read<Value: Decodable>(
        _ type: Value.Type,
        from url: URL
    ) throws -> Value {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Value.self, from: data)
    }

    private func excludeFromBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }
}
