# ADR 0004: Final Cut-style library bundle

**Status:** Accepted, 2026-10-10

## Decision
One `.clipperlib` package holds the index, projects, templates, copied-in media, proxies and the analysis cache. On import, the user chooses either "copy into library" or "leave in place" (stored as a security-scoped bookmark plus a path).

## Consequences
- Analysis results are reused across projects, keyed by a content hash.
- Media left in place can be re-linked by `assetKey` after it moves.
- Backup is a single folder.
