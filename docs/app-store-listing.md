# App Store listing

Written 16 September 2026. The competitive numbers are from the App Store's own
search API; the listing facts are read out of App Store Connect.

## Where we actually stood

1.0.0 was approved on 12 September and then sat on sale in **zero countries for
four days** — the app had no territory availability record at all. That is why
an `itunes.apple.com/lookup` on the bundle id returned nothing, and it is not a
listing problem. Fixed on the 16th; 175 territories, processing.

Two consequences worth keeping in mind when reading anything below:

- The shipped binary is **1789244768, uploaded 12 September 20:34 UTC**, which
  predates `454c876`. On the store today the assistant **reads** calendar,
  reminders and Health and **cannot write anything**. Any copy that says it sets
  reminders is false against that build and has to wait for 1.0.1.
- 1.0.1 must carry a build cut from `5dafcd0` or later, because the app target
  did not compile for three commits before it.

## What the category is doing

Ranked by `itunes.apple.com/search` for the four queries a buyer types —
"local llm", "offline ai", "private ai", "on device ai":

| App | Price | Rating | Ratings | Category |
|---|---|---|---|---|
| Locally AI by LM Studio | Free | 4.7 | 1,598 | Productivity, Utilities |
| Enclave — Local AI Assistant | Free | 4.7 | 1,062 | Productivity, Entertainment |
| Private LLM — Local AI Chat | $4.99 | 4.2 | 720 | Utilities |
| Liquid Apollo | Free | 4.5 | 634 | Utilities, Productivity |
| PocketPal AI | Free | 4.1 | 154 | Productivity, Entertainment |

Every one of them is the same app: a chat window, a model downloader, and the
words offline, private, no account. They compete on which models you can run and
how fast.

Searching all five descriptions for `calendar`, `reminder`, `health`,
`schedule`, `contacts` or `email` returns **nothing**. Two mention Siri and
Shortcuts, which is a generic automation hook rather than the app reading
anything itself.

**Not one of them is in Developer Tools.** We were, which is the single biggest
thing that was wrong.

## The position

**Offline AI is private and useless. A model that knows nothing about you is a
worse ChatGPT with a better privacy policy.**

The reason to run AI on the phone is not privacy in the abstract. It is that the
phone is already where your calendar, your reminders and your health live.
Privacy is what makes it safe to let the model *in* — and letting it in is the
product.

The app's own UX already made this call: `RootView` opens on Abilities, and its
comment says so at length — *"Was `.server`, which is the line that made this a
server product."* The listing never followed.

## Changes applied (by the EM, in ASC)

- **Primary category PRODUCTIVITY, secondary UTILITIES** — was DEVELOPER_TOOLS.
  On 1.0.1; live 1.0.0 returns 409 for a category change.
- Subtitle → `Sets reminders. Sends nothing.` (30/30)
- Keywords → `local llm,llama,qwen,calendar,todo,private,on-device,siri,health,gguf,gemma,offline,assistant,ai`
  (96/100). The old field spent half its length on `selfhosted,homelab,lan,endpoint,developer,inference`
  — all supply-side. `calendar` and `health` are the two words no competitor can
  claim, and `offline`, `assistant` and `ai` had to be bought back once the name
  turned out to carry no search load at all.

  `no internet` was dropped for `offline`: eleven characters to contribute "no"
  and "internet" to a field Apple reads as a combination builder, where the same
  claim in seven characters is an actual query. That paid for `gguf` and `gemma`.
  `gguf` is worth its four characters because somebody typing it has already
  decided they want to run a local model and is looking for something to run it
  in — the highest-intent, lowest-competition term available.
- Promotional text, description (2,898/4,000) and screenshot order — staged.
- Live 1.0.0 got a **read-only** promo text, since that is the one field
  editable without review and the shipped binary cannot write.

- App name → `Pocketd: Future is here` (23/30), the user's own choice, replacing
  `Pocketd: Local LLM Server`. "Server" told a consumer the app was not for
  them, so dropping it is right. The cost is that the name now carries no search
  term at all, which is why the keyword field had to absorb `offline`,
  `assistant` and `ai`.

  It went out briefly as "Pocktd" — a typo, caught by rendering a screenshot and
  reading it. `CFBundleDisplayName` is `Pocketd` in both targets and 22 strings
  in the app say Pocketd, so the store would have sold an app whose home screen
  icon disagreed with its listing. Everything now agrees and no build was
  needed.

## Two things about the fields themselves

**The subtitle is per-locale, exactly like the keyword field.** Apple weights it
second only to the name. Three storefronts inheriting the en-US string is three
separate indices doing one field's work, and there is no brand cost, because
nobody sees two storefronts — a user in Sydney sees one subtitle and a user in
Toronto sees another, and neither can tell they differ.

| locale | | subtitle |
|---|---|---|
| en-US | 30/30 | Sets reminders. Sends nothing. |
| en-GB | 29/30 | Your calendar, answered here. |
| en-AU | 26/30 | No signal. Knows your day. |
| en-CA | 30/30 | Reads your week. Uploads none. |

Each was checked against **its own locale's** keyword field. A word in both is
paid for twice and indexed once.

**Apple does not index the description.** Unlike Google Play it is a conversion
asset and not a discovery one, which is why the subtitle and the keyword field
carry the ranking — and why the pressure to work search terms into those 2,898
characters is a pressure to make them worse for no gain. They are answerable
only to whether they persuade.

## Screenshots

The five on the store are bare device captures — no caption, no frame, no accent
colour. Both leaders do the same thing as each other and neither does that.

Worse than the styling:

- Slot 1 was `05-onboarding.png`, whose headline is literally **"Your iPhone is
  the server."** The first thing every visitor saw was the positioning we are
  trying to leave.
- `01-chat.png` asks *"Why is running a language model on my own phone more
  private than a cloud API?"* and the answer is generic prose about encryption.
  It is the model talking about itself — a live demonstration of the "worse
  ChatGPT" position.
- `03-deskmode.png` is a near-black screen with an IP address on it.
- **None of the five shows calendar, reminders or Health.** The differentiator
  is invisible.

`scripts/store-shots.py` builds the new set: bold caption above a device frame,
one benefit per shot, exactly one accent word, 1320×2868.

### Done

`docs/store/06-server.png` — "Also: your phone is an AI server." over the Server
tab, live: SERVING, the address, the pairing code, the setup URL. Shot on a
simulator because it needs no model. Deliberately the LAST slot — after five
shots about the assistant it reads as "and also this", which is the same job it
does in the description. No competitor serves an OpenAI-compatible API off the
phone at all, so it is worth a slot; it is just not worth the first one, which
is the mistake the old set made.

`docs/store/05-privacy.png` — "Three addresses. Nothing else." over the data
inspector, showing a real byte count, a real file count and the three named
destinations. No competitor can take this picture; theirs is a paragraph.

The caption was "Nothing leaves the phone." and that was wrong, not merely
weak. It sat directly above the screen's own header — "What leaves this
device" — and three addresses, one of them `api.mixpanel.com`. The frame
refuted itself in about a second, on the shot whose entire job is being
believed. Caught by the engineering manager reading the picture rather than
the plan.

### The four that need a real phone

A tool-capable model is 1.1GB and the simulator reports **722MB usable**, so
every model in the catalogue reads "Too large" there — the increased-memory
entitlement does not change it, because the figure comes from
`os_proc_available_memory()`. These have to be shot on the device:

| file to save | what to capture |
|---|---|
| `chat-calendar.png` | Ask **"what's on tomorrow?"** with two or three real events in the calendar. Capture the answer with the calendar card visible. |
| `chat-reminder.png` | Ask **"remind me to take the bins out at 2am"**. Capture the confirmation naming the time it set. |
| `chat-repeat.png` | Ask **"remind me every weekday at 7am to take my pills"**. Capture the confirmation saying it repeats. |
| `abilities.png` | The Abilities screen with Calendar and Reminders on. Must be a phone: on a simulator the only model that fits is one `ToolGate` refuses, so the screen always carries an orange "SmolLM2 360M is not able to use these tools" caveat. |

**Use invented data.** These publish to 175 countries permanently, from the app
whose pitch is that your calendar never leaves the phone. Two or three plain
calendar entries, no real names, no companies, no addresses, nothing medical.

**Shoot from build 1789543153 via TestFlight.** It is the first build that both
contains the write path and compiles — `454c876` and `ff217c6` do not build, so
no binary from them exists. Whoever takes the reminder captures is exercising
that feature for the first time on hardware. If "remind me to take the bins out
at 2am" does not produce a confirmation, that is a defect to report, not a bad
capture to retake.

### The App Preview video — same session, same phone

Apple wants App Previews captured from the app in use, 15–30 seconds, up to
three per locale. Compositing stills with motion is not that, and a rejection
on a video is expensive.

The best ten seconds of any preview we could make is the assistant answering
from a real calendar, which needs a tool-capable model, which needs the phone
for the same reason the stills do. So it comes out of the same session — screen
recording is in Control Centre, so it costs nothing extra while the staged data
is already in place.

**One continuous take, about 20 seconds, no editing.** Start the recording on
the Chat tab with a model already loaded, then:

1. Type `what's on tomorrow?` and send. Let the answer card finish rendering
   and sit on it for two seconds — that card is the whole product.
2. Type `remind me every weekday at 7am to take my pills` and send. Let the
   confirmation land and sit on it for two seconds.
3. Stop.

Do not tap around afterwards, do not visit Settings, and do not show the Server
tab. The preview has one job: someone who has never heard of this app sees a
phone answering a question about its owner's day, offline. Everything else is
the listing's job.

The staged-data rule matters more here than on the stills, because a video
shows more of the screen for longer. Same constraint: invented entries, no real
names.

Then:

```bash
python3 scripts/store-shots.py <folder-with-those-pngs> docs/store/
```

The script names anything still missing. Models is deliberately out of the set:
every leader competes on which models run and how fast, so a model grid puts us
back on the axis where they have MLX, OmniQuant and a thousand ratings each.
