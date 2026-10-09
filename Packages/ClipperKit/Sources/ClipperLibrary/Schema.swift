import Foundation
import GRDB

/// The index schema. Migrations are append-only: never edit a shipped migration, add "v2", "v3"…
///
/// Conventions: ids are TEXT (UUID strings, readable from the `sqlite3` shell); dates are REAL seconds since the
/// reference date (exact round-trip); complex values are JSON TEXT written with `ClipperJSON`.
enum Schema {
    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()

        m.registerMigration("v1") { db in
            try db.create(table: "asset") { t in
                t.primaryKey("id", .text)
                t.column("key", .text).notNull().unique()
                t.column("name", .text).notNull()
                t.column("kind", .text).notNull()
                /// Relative to the bundle for managed (copied) media, absolute otherwise.
                t.column("path", .text).notNull()
                t.column("bookmark", .blob)
                t.column("managed", .boolean).notNull()
                t.column("imported", .double).notNull()
                t.column("info", .text).notNull()       // MediaInfo JSON
                t.column("tags", .text).notNull()       // [String] JSON
                t.column("playablePath", .text)
                t.column("proxyPath", .text)
            }

            try db.create(table: "project") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("created", .double).notNull()
                t.column("modified", .double).notNull().indexed()
                t.column("timelineCount", .integer).notNull()
                t.column("path", .text).notNull()       // relative to the bundle
            }

            try db.create(table: "music") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("artist", .text).notNull()
                t.column("track", .text).notNull()      // MusicTrack JSON
                t.column("updated", .double).notNull()
            }

            try db.create(table: "settings") { t in
                t.primaryKey("id", .integer).check { $0 == 1 }
                t.column("json", .text).notNull()
            }

            try db.create(table: "analysis") { t in
                t.column("assetKey", .text).notNull()
                t.column("analyzer", .text).notNull()
                t.column("version", .integer).notNull()
                t.column("bytes", .integer).notNull()
                t.column("updated", .double).notNull()
                t.primaryKey(["assetKey", "analyzer"])
            }

            try db.create(table: "job") { t in
                t.primaryKey("id", .text)
                t.column("kind", .text).notNull()
                t.column("title", .text).notNull()
                t.column("payload", .blob)
                t.column("status", .text).notNull().indexed()
                t.column("progress", .double).notNull()
                t.column("error", .text)
                t.column("created", .double).notNull()
                t.column("updated", .double).notNull()
            }
        }

        return m
    }
}
