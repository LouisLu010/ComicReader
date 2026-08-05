import SwiftData

enum ComicReaderMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [
            ComicReaderSchemaV1.self,
            ComicReaderSchemaV2.self,
            ComicReaderSchemaV3.self,
        ]
    }

    static var stages: [MigrationStage] {
        [
            .lightweight(
                fromVersion: ComicReaderSchemaV1.self,
                toVersion: ComicReaderSchemaV2.self
            ),
            .lightweight(
                fromVersion: ComicReaderSchemaV2.self,
                toVersion: ComicReaderSchemaV3.self
            ),
        ]
    }
}
