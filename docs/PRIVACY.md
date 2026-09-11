# Privacy Policy

**Pocketd** · Last updated 11 September 2026

Pocketd collects nothing. There is no account, no analytics, no crash
reporting and no telemetry, and no server belonging to this project exists to
receive any. Nothing you type, and nothing the model says back, ever leaves
your phone.

The rest of this page is the detail behind that sentence, including the parts
that are less tidy than the sentence is.

## What Pocketd collects about you

Nothing. Specifically:

- No account, no sign-in, no email address, no identifier of you or your
  device.
- No analytics or usage measurement of any kind.
- No crash reporting.
- No advertising, no ad identifier, no tracking, and no data shared with
  anyone for any purpose. Pocketd does not link an advertising framework and
  never asks for permission to track, because there is nothing to track with.
- No third-party SDK that collects anything. Pocketd links exactly two
  outside components — an HTTP server ([FlyingFox]) and the inference runtime
  ([LocalLLMClient], wrapping [llama.cpp]). Neither reports anything anywhere.

This is also what the app's `PrivacyInfo.xcprivacy` declares to Apple: tracking
off, tracking domains empty, collected data types empty.

## What leaves your phone

One host: **`huggingface.co`**, and the CDN that `huggingface.co` redirects
downloads to. Only two things ever cause a request:

| When | What is sent |
| --- | --- |
| You search for a model | The text you typed, as a search term, and your phone's IP address |
| You open a repository to see its files | The repository's name, and your phone's IP address |
| You download a model | Which repository and file you are fetching, and your phone's IP address |

A paired device on your network can ask the phone to run a search or start a
download on its behalf, which sends the same things and nothing more.

No account, no token and no identifier of yours is attached to either. Every
download address is assembled as `huggingface.co`, then a repository and a
filename; the search API accepts a repository and a filename and never a host.
The stored record for a model carries a field that could name a different
address, and nothing in the app or its HTTP API ever sets it.

Nothing else is contacted. Inference does not call out — the weights are a file
on your phone, and answering a question reads that file. The web pages Pocketd
serves are self-contained, with no fonts, scripts or images loaded from
anywhere.

## Health, Calendar and Reminders

If you grant access, the assistant can answer questions about your activity,
heart and sleep, your calendar and your reminders.

- **The data is read on this device and is never uploaded.** It goes to a file
  of weights on your phone and comes back as an answer.
- **Network callers cannot reach it.** Pocketd serves other devices on your
  network, and those devices are refused this data — including the chat page
  Pocketd itself serves, which is treated as a network client like any other.
  The decision is made from the connection's own peer address, before any read
  happens, so a refused request causes no read at all rather than a filtered
  one. Only someone holding the phone and using the Chat tab can get an answer
  containing personal data.
- **Health data is never used for advertising or marketing, never sold, and
  never disclosed to anyone.** There is nowhere for it to go.
- **Pocketd never writes to Health.** The write permission string exists only
  because iOS requires one from any app that links HealthKit.
- **Health data stays out of iCloud.** Conversation transcripts are excluded
  from iCloud Backup, because an answer about your sleep or resting heart rate
  is saved in the transcript along with the rest of the conversation.

One thing Pocketd cannot tell you: **iOS never reports to an app whether a
request to read Health was allowed.** That is deliberate on Apple's part — it
stops an app distinguishing "you said no" from "you have no data of that
kind" — and it applies to Pocketd like every other app. The app's own Data
screen says so rather than guessing. Health → Data Access & Devices → Pocketd
is the only place with the answer.

## What is stored on your phone

Everything Pocketd keeps stays inside the app's own container:

- **Models** you downloaded. Not about you.
- **Conversations** — everything typed in the Chat tab and everything the
  model replied, as plain text, one file each.
- **Settings**, including the API key other devices use to reach this phone.
- Caches iOS keeps on the app's behalf, and snapshots iOS takes of the app
  when you switch away.

Models and conversations are both excluded from iCloud Backup. The Data screen
inside the app walks the container and accounts for every byte, names what it
cannot delete and says who can, and offers to delete the rest. Deleting the app
removes all of it.

## The local network

When you press Start, your phone runs an HTTP server for other devices on your
Wi-Fi.

- **The server only answers.** It accepts connections and never opens one.
- While it is running, the phone **announces itself over Bonjour** to everyone
  on the same Wi-Fi: the device name iOS knows it by, the app version, which
  APIs it speaks, whether a key is required, and the id of the loaded model.
  That is how a laptop finds the phone without anyone typing an address. It
  does not leave the local network, and it stops when the server stops.
- Requests can require a key, and pairing is a six-digit code shown on the
  phone. Anything reaching the server still cannot read your Health, Calendar
  or Reminders — see above.

## The awkward parts

Worth saying plainly, because they are real and they are the kind of thing a
privacy page usually leaves out:

- **Opening a model's page hands the address to Safari.** What Safari sends
  from that point is Safari's business, with Safari's cookies, not Pocketd's.
- **Copying the API key or the server address puts it on the system
  pasteboard.** If Handoff is on, Universal Clipboard forwards the pasteboard
  to your other Apple devices through iCloud. That is an iOS feature and
  applies to anything you copy.
- **Hugging Face sees your IP address** when you search or download, as any
  website does, and its CDN may set cookies that the system's HTTP client
  stores. The Data screen lists that cache and can delete it.

## Children

Pocketd has no account, no sign-up and no social features, and collects nothing
from anyone, of any age.

## Changes

This policy is versioned with the source. Its history is the file's history in
the repository, so any change to it is a diff someone can read.

## Contact

Questions, or something here that does not match what the code does:
<https://github.com/dheerajjha/pocketd/issues>. The app is open source — the
claims on this page are checkable against the source rather than taken on
trust.

[FlyingFox]: https://github.com/swhitty/FlyingFox
[LocalLLMClient]: https://github.com/tattn/LocalLLMClient
[llama.cpp]: https://github.com/ggml-org/llama.cpp
