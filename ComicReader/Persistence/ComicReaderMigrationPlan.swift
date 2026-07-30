import SwiftData

enum ComicReaderMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [ComicReaderSchemaV1.self]
    }

    static var stages: [MigrationStage] {
        []
    }
}
