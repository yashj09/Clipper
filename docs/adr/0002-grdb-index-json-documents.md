# ADR 0002: GRDB/SQLite index plus JSON documents, not SwiftData

**Status:** Accepted, 2026-10-10

## Decision
- Store the library index (assets, analysis index, jobs, settings) in SQLite through GRDB, in WAL mode.
- Store projects and templates as human-readable, versioned Codable JSON files.

## Why
- SwiftData's migrations are opaque.
- SwiftData is awkward under Swift 6 strict concurrency.
- SwiftData is risky when the CLI and the app open the same store at once.
- GRDB gives explicit migrations, safe access from several processes, and `ValueObservation` for SwiftUI.
- Plain JSON documents can be diffed, edited by hand, mapped to OTIO, and saved as templates almost for free.
