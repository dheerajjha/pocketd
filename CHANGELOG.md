# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [semantic versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- OpenAI-compatible API: `GET /v1/models`, `GET /v1/models/{id}`,
  `POST /v1/chat/completions` (buffered and SSE-streamed), `POST /v1/completions`.
- Ollama-compatible API: `GET /api/tags`, `POST /api/chat`, `POST /api/generate`,
  `POST /api/show`, `GET /api/ps`, `GET /api/version`, plus the `HEAD` probes and
  the `Ollama is running` root that Ollama clients check before anything else.
- `stream_options.include_usage`, answered with the empty-`choices` usage chunk
  the OpenAI streaming spec requires.
- Bearer-token authentication with a constant-time comparison, optional CORS,
  and single-flight admission control so a second request is refused rather than
  made to compete for one GPU.
- Model catalogue with a device memory budget: downloads that cannot fit are
  warned about with the numbers that make the warning checkable, and can still
  be overridden.
- Resumable model downloads that survive the app being suspended mid-transfer.
- Live request log with per-request tokens per second, held in memory only.
- SwiftUI app: Server, Models, Chat and Settings.

### Known limitations

- Sampling parameters are bound when the model loads, so per-request
  `temperature`, `top_p` and `top_k` are ignored. `max_tokens` and `stop` are
  enforced by the server.
- `usage` token counts are a 4-characters-per-token estimate, not the model's
  tokenizer.
- Embeddings are not implemented; the endpoints answer `501`.
