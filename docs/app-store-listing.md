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
- Keywords → `local llm,gguf,llama,qwen,gemma,calendar,todo,agenda,private,on-device,chatbot,health,no internet`
  (97/100). The old field spent half its length on `selfhosted,homelab,lan,endpoint,developer,inference`
  — all supply-side. `calendar` and `health` are the two words no competitor can claim.
- Promotional text, description (2,898/4,000) and screenshot order — staged.
- Live 1.0.0 got a **read-only** promo text, since that is the one field
  editable without review and the shipped binary cannot write.

Still with the user: the app **name**. It is `Pocketd: Local LLM Server`.
"Server" tells a consumer the app is not for them. Recommend at minimum
`Pocketd: Offline AI Assistant` (29/30); whether to keep the Pocketd brand at
all is a separate and bigger question.

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

### The three that need a real phone

A tool-capable model is 1.1GB and the simulator reports **722MB usable**, so
every model in the catalogue reads "Too large" there — the increased-memory
entitlement does not change it, because the figure comes from
`os_proc_available_memory()`. These have to be shot on the device:

| file to save | what to capture |
|---|---|
| `chat-calendar.png` | Ask **"what's on tomorrow?"** with two or three real events in the calendar. Capture the answer with the calendar card visible. |
| `chat-reminder.png` | Ask **"remind me to take the bins out at 2am"**. Capture the confirmation naming the time it set. |
| `chat-repeat.png` | Ask **"remind me every weekday at 7am to take my pills"**. Capture the confirmation saying it repeats. |

Then:

```bash
python3 scripts/store-shots.py <folder-with-those-pngs> docs/store/
```

The script names anything still missing. `abilities`, `privacy`, `models` and
`server` can be shot on a simulator and are the remaining four slots.
