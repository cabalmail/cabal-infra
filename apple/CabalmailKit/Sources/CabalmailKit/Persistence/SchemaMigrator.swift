import Foundation

/// Forward-only schema migrations for one SQLite file, keyed on its
/// `user_version`: step N takes the file from version N-1 to N, so a file
/// is at the version of the last step that ran.
///
/// Each step and its `user_version` write share one transaction (SQLite DDL
/// is transactional), so a crash or a failure mid-step leaves the previous
/// version intact rather than a half-applied one that fails on every rerun.
struct SchemaMigrator: Sendable {
    /// One step: SQL, or code for a change SQL alone cannot make.
    struct Step: Sendable {
        let apply: @Sendable (SQLiteDatabase) throws -> Void

        init(_ apply: @escaping @Sendable (SQLiteDatabase) throws -> Void) {
            self.apply = apply
        }

        static func sql(_ sql: String) -> Step {
            Step { try $0.exec(sql) }
        }
    }

    /// What to do with a file whose `user_version` is past the last step
    /// here: a newer build wrote it, and this one was installed over it.
    enum NewerSchemaPolicy: Sendable {
        /// Throw, for the caller to recover from. For a file this build
        /// would misread, such as a cache with columns it does not know.
        case refuse
        /// Run no step and leave the version as it is. For a file whose
        /// schema only ever grows, which an older build can still use.
        case useAsIs
    }

    /// What an error calls the file (`rss.sqlite`).
    let name: String
    let steps: [Step]

    /// The version a file is at once every step has run.
    var version: Int { steps.count }

    /// Brings `database` up to `version`. A file already there costs one
    /// read and takes no lock.
    func migrate(_ database: SQLiteDatabase, newerSchema: NewerSchemaPolicy) throws {
        let found = try database.userVersion()
        guard found >= 0 else {
            throw CabalmailError.storage("\(name) has no usable schema version (\(found))")
        }
        if found > version {
            switch newerSchema {
            case .refuse:
                throw CabalmailError.storage("\(name) schema \(found) is newer than this build's \(version)")
            case .useAsIs:
                return
            }
        }
        for _ in found..<version {
            try database.transaction {
                // Read again now that the write lock is held: another
                // connection on the file (a second client's store) may have
                // run this step since the read above.
                let current = try database.userVersion()
                guard current < version else { return }
                try steps[current].apply(database)
                try database.setUserVersion(current + 1)
            }
        }
    }
}
