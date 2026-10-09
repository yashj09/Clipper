# ADR 0003: Render text and captions inside the Metal compositor

**Status:** Accepted, 2026-10-10

## Decision
Lay out text and captions with Core Text into cached Metal textures, then animate them with shader uniforms inside `ClipperCompositor`. Don't use `AVVideoCompositionCoreAnimationTool`.

## Why
The CoreAnimation tool works only for export. In preview it would need a separate `AVSynchronizedLayer`, so preview and export would drift apart. One renderer guarantees the output matches the preview. The same caption layout data also feeds SRT, VTT and ASS export.
