# ADR 0007: Local LLM through an OpenAI-compatible localhost server, not embedded

**Status:** Accepted, 2026-10-11 (Phase 2)

## Context
Highlight ranking benefits from a language model that judges "is this a good standalone short?". The original plan was MLX Swift inside the app.

## Decision
- Clipper never embeds a model.
- Clipper ranks with transparent heuristic signals by default.
- Optionally, it re-ranks through a **user-run OpenAI-compatible server on localhost**:
  - Ollama (`:11434/v1`)
  - LM Studio (`:1234/v1`)
  - `mlx_lm.server` (`:8080/v1`)
- Requests use JSON-schema-constrained output, with fallbacks for servers that don't support it.

## Why
- **App stays small.** Embedding MLX adds gigabytes of weights, a large dependency, and memory pressure inside the editor process. A 14B model needs about 9 GB, competing with decoding and the GPU compositor.
- **User choice.** People already run Ollama or LM Studio, and they pick the model and quantization.
- **Still fully local.** Zero cloud calls. Only `localhost` endpoints are suggested.
- **Graceful fallback.** The heuristic ranker works with no model at all.

## Consequences
- Using the LLM is a two-step setup: start a server, then enable it in Settings.
- Server compatibility varies: some don't support `json_schema`, so the client retries with `json_object` and then with no format constraint.
