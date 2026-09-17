# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [semantic versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - Unreleased

### Added

- Today opens on a daily brief written from the calendar, reminders and
  sleep, with tiles for what's next, what's due, sleep and steps underneath
  it.
- A Home Screen and Lock Screen widget mirrors the brief and opens straight
  to Today.
- Holding the mic button on Ask lets you ask by speaking, recognized
  entirely on the device, and a Read aloud button speaks the brief or an
  answer back.
- An Ask Pocketd control opens the app straight into a ready composer from
  Control Center, the Lock Screen or the Action Button.
- Routines offers one-tap templates for a morning brief, an evening
  wrap-up, a weekly review, and a watcher for overdue reminders.
- First run now downloads a model sized for the phone, connects Calendar,
  Reminders and Health one at a time, takes a name for the greeting, and
  sets up the morning brief before Today opens for the first time.
- A shared design system — palette, type scale, spacing scale and a set of
  reusable components — underlies every screen.
- `pocketd://today` and `pocketd://ask` deep links let a widget tap or a
  shortcut open straight to a tab.
- Seven analytics events for onboarding, the brief, voice and routines join
  the closed set in `AnalyticsEvent.swift`.

### Changed

- The five-tab shell — Abilities, Server, Models, Chat, Settings — is
  replaced by four tabs — Today, Ask, Routines, You — with Brain, Other
  devices, Privacy, Settings and Diagnostics reachable from You.
- The Chat tab is now Ask: the same conversation engine, restyled with
  structured answer cards for events, reminders and health instead of plain
  text.
- The Schedules sheet is now the Routines tab, with a preview of each
  routine's last result shown on its card.

### Fixed

- A reply after a tool call sometimes showed the raw JSON payload handed to
  the model instead of its narration; the echo is now detected and
  withheld.
- Ability summaries are capped at a tested length so a row in Abilities or
  You can no longer be truncated mid-word.

## [1.0.1] - 2026-09-17

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
- App Intents for Siri, Shortcuts, Spotlight and the Action Button, so a
  question can be asked without opening the app first.
- Writes to Calendar and Reminders — set a reminder, add an event, including
  ones that repeat — gated to the chat tab so a network client or a
  scheduled run can never change anything.
- A diagnostics log in Settings: a capped, copyable record of tool calls
  and permission decisions, with a closed set of event types so nothing
  personal can appear in it.
- A rating prompt, shown after three tool-backed answers, at most three
  times a year and never in the first two days.

### Known limitations

- Sampling parameters are bound when the model loads, so per-request
  `temperature`, `top_p` and `top_k` are ignored. `max_tokens` and `stop` are
  enforced by the server.
- `usage` token counts are a 4-characters-per-token estimate, not the model's
  tokenizer.
- Embeddings are not implemented; the endpoints answer `501`.
