# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [semantic versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.1] - Unreleased

### Added

- Pocketd Pro can be bought from Pocketd's page on the App Store. A purchase
  started there opens Pocketd and runs the same purchase as the Pro sheet; it
  is skipped for anyone who already has Pro, bought or early.

### Changed

- The App Store rating question now counts a tile's page that showed
  something from your own calendar, reminders or health, as well as answers in
  the conversation. Same limits as before: three such answers, never in the
  first two days, and at most once every 120 days.

## [1.1.0] - 2026-10-21

### Added

- Today is the one home: a short brief about your day, written from your
  calendar, reminders and health, above four tiles — Up next, Due, Sleep and
  Activity — that each give a verdict ("Rested", "1 overdue", "Ahead") and one
  sentence comparing it with your usual.
- Each tile opens a page read straight from Calendar, Reminders or Health,
  never written by the model: Your day (now, later today and tomorrow, with
  Directions and Open in Calendar), Reminders (tick one off, with Undo), and
  Sleep and Activity (your usual against last night or today, and the last
  seven days).
- Built into iPhone: on iOS 26 and later with Apple Intelligence on, Pocketd
  answers with Apple's on-device model through the FoundationModels
  framework, with nothing to download. It runs the same calendar, reminders
  and health tools as a downloaded brain, and it is the default on a fresh
  install wherever it is available.
- Pocketd Pro, a one-time in-app purchase. It unlocks Use from your laptop,
  the Evening wrap-up, Weekly review and Custom routines, and brains beyond
  the recommended one, including Hugging Face search. Anyone who installed
  Pocketd from the App Store before 1.1.0 gets it free. Restore purchase is
  in You › About.
- One-tap routine templates for a Morning brief, an Evening wrap-up, an
  Overdue nudge and a Weekly review, beside Custom for one of your own.
- A Home Screen and Lock Screen widget mirrors the brief and opens Today.
- Holding the mic in the conversation asks by speaking, recognized entirely
  on the device, and the mic on Today and on each page opens the
  conversation already listening. A Read aloud link speaks the brief.
- An Ask Pocketd control opens the conversation, listening, from Control
  Center, the Lock Screen or the Action Button.
- A reminder or an event the assistant adds comes with an Undo that lasts
  five minutes.
- `pocketd://today`, `pocketd://ask`, `pocketd://routines` and
  `pocketd://you` deep links.
- A shared design system — palette, type scale, spacing scale and a set of
  reusable components — underlies every screen.
- Seven analytics events, for the intro, the brief, voice, answers, routines
  and the Today tiles, join the closed set in `AnalyticsEvent.swift`, which
  is now twenty-eight cases long.

### Changed

- The five tabs — Abilities, Server, Models, Chat and Settings — are
  replaced by one home with no tab bar. Today is the root; Routines and You
  open from its header, and the conversation is a sheet that opens over
  wherever you are.
- Chat is now the conversation sheet: one card per answer, with a timeline
  of events, a checklist of reminders or a grid of health numbers inside it,
  one suggested follow-up, and one notice at a time. A question asked from
  Today or a page starts a new conversation unless the open one was used in
  the last half hour.
- Models is now Brain, under You: Built into iPhone, or one private download
  chosen for this phone, Qwen3 1.7B at 1.11 GB. The rest of the catalogue
  and Hugging Face search are under More brains, each brain marked "Reads
  your day" or "Chat only", and a brain that cannot read your day is never
  recommended and never writes the brief.
- Server is now Use from your laptop, under You, with desk mode, recent
  requests and server settings on the same page. It serves downloaded GGUF
  brains only; Apple's model is never served.
- Abilities is now What Pocketd can see, at the top of You: one switch each
  for Calendar, Reminders and Health, and the switch is what asks iOS.
- The Schedules sheet is now Routines, opened from the ⏰ on Today. Each
  routine is an alarm-style card: the time, its days, a switch, and a line
  from its last result. The Schedules widget is now the Routines widget, and
  a tap on it opens Routines.
- Settings is split. The usage-counts switch and the file-by-file account of
  what Pocketd stores are under You › Privacy; assistant instructions, server
  settings and diagnostics are under You › Advanced.
- First run is five screens with no Skip: Meet Pocketd, Choose how Pocketd
  thinks, Connect your day, Get your day every morning, and You're all set.
- The morning brief is a routine like the others: at the time you set, a
  notification says "Your morning brief is ready." and opens Today, where the
  brief is written. It no longer needs the app open at that hour.
- Thinking is off for everything the phone writes for itself. "Think before
  answering", in Server settings, affects other devices only.
- Permission prompts are one or two short sentences each, saying what the
  permission is for.

### Fixed

- Stop really stops. With a downloaded brain, Stop now interrupts llama.cpp
  at once, even while it is still reading the prompt, instead of letting it
  generate on in the background and hold the brain through a switch;
  switching or removing a brain stops it first. A stopped reply says
  "Stopped.", including one cut off when the app was closed.
- A new routine can be saved. The editor compared drafts by identity alone,
  so every edit was dropped and Save never lit up.
- Long conversations no longer die. History is trimmed to fit the brain's
  window before every answer, a failure is one plain sentence, and when a
  conversation really is too long, the notice offers to start a new one.
- Dynamic Type: text on every screen follows the size set in Settings, and
  layouts reflow at the largest sizes instead of truncating — the tiles go to
  one column and rows wrap. Controls are at least 44 points, secondary text
  meets WCAG AA contrast, and hold-to-talk has a VoiceOver action.
- Events and reminders keep the time you said. "Remind me to call mom at
  6pm" could be saved for tomorrow, or with no time at all; a time with no
  day now means the next time it comes round, "9 tomorrow" means nine rather
  than noon, and "Friday 5" means the coming Friday rather than the fifth of
  a month.
- An event you gave no length to was saved with whatever length the model
  invented, from half an hour to eight hours. It now lasts an hour unless you
  say how long, and the card always says the length.
- An answer that repeats the assistant's own instructions is caught before
  it is shown.
- A reply after a tool call sometimes showed the raw JSON payload handed to
  the model instead of its narration; the echo is now detected and
  withheld.
- A question from Siri or a Shortcut asked while no brain was ready is sent
  once one is, instead of being left unsent.
- A chat stream from another device stops generating when that device hangs
  up, freeing the phone in seconds instead of holding it.
- "New code" stays available while the server runs, so a second device can
  always be paired.
- The thinking switch and the context limit in Server settings now reach the
  engine; they used to be saved and then ignored.

### Removed

- The tab bar.
- "Offload when backgrounded" and "Offload after idle". Loading a brain and
  letting it go are automatic.
- The override that downloaded a brain too big for the phone. A brain that
  will not fit says "Too big for this iPhone" instead of offering a button.

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
