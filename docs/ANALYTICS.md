# Product analytics

Pocketd reports bounded product interactions, not questions, answers, model output,
conversation contents, Health/Calendar/Reminder readings, network addresses, hostnames,
raw user agents, prices, product identifiers, transactions or Apple Account details.
The app adds no crash reporting. Mixpanel's existing SDK IP-geolocation default remains
enabled; the app does not add Core Location or a custom IDFV. Debug uses `NoAnalytics`.

## Runtime and consent

`AnalyticsEvent` is the catalogue; `AnalyticsSchema` independently lists event keys
and context keys. `ProductAnalytics` is AppModel's runtime door, including the
server-log observer; `MixpanelAnalytics` only flattens the typed values into the SDK.
Existing analytics consent remains default-on when absent, with stored refusal,
`stopAndForget` and `resume` unchanged. Refused/undecided actions are not emitted or
replayed, and no consent-result event is emitted on refusal. A `NoAnalytics` sink
does not consume first value. SDK reset does not reset the product latch.
Consent transitions also discard delayed requests started before the transition,
so an opt-out generation finishing after opt-in is not replayed.

The catalogue has 46 events (33 existing, 13 added). The existing live privacy page
describes the live binary, not this future candidate. Its numeric event-count copy
will need a separate release-time review; this change does not edit that page or
the privacy manifest/labels.

## Journey inventory

| Step | Existing tracking | Expansion / limit |
| --- | --- | --- |
| Install / cold launch | `app_opened(is_first_launch)` after bootstrap reconciliation; `FirstLaunch` persists prior-use evidence | `app_foregrounded` gives an exposure denominator before fallible bootstrap work; persisted analytics install timestamp |
| Onboarding | `onboarding_step_viewed(step)` and `onboarding_completed(via,destination)` for actual intro/replay actions | `screen_viewed(onboarding)`; bounded permission-request attempts/results; no duplicate step events |
| Find a brain | Download start/completed/cancelled/failed, oversize override; model load succeeded/failed with RAM bucket and bounded reason | Navigation screens now measurable; existing download/load events gain context through the common runtime door |
| First server value | External/on-device connection events existed in the enum but had no runtime emitter | Log observer now emits only for a terminal, non-cancelled generation; first external success persists `first_value_reached` |
| Repeat local chat | `chat_message_sent(model_id)`, voice use, answer feedback, ability offers | Numeric `error_shown(chat)` on actual failure notice; local send/tokens are deliberately not first value |
| Repeat LAN use | `server_started`, `server_stopped(served_s)` | External/on-device successful request events; no address/model/token counts added to them |
| Today | Brief generated with source/duration, read aloud, tile taps | Root/detail navigation screens; no personal readings or content-derived first-value trigger |
| Routines | Created template, task ran kind/context, task lapsed | Routines/result screens and a rollup when a notification is consumed; no routine titles, IDs, prompts or results |
| Paywall | Purchase started/completed/cancelled/pending/failed and entry | `paywall_viewed` once per presentation and one fixed lifetime `plan_selected`; no invented plan picker |
| Purchase / restore | Verified transaction listener and purchase outcomes; restore UI without events | Restore started/result, numeric purchase/restore errors; direct analytics-only plan publication/invalidation, independent of access gates |
| Permissions | Ability enabled/disabled, in-chat offers | Calendar/Reminders/Health request attempts and outcomes; notification requests and fresh status context |
| Settings / sharing | Configuration persisted, address/diagnostic clipboard actions untracked | Changed authentication/reasoning/keep-awake booleans; address/diagnostic share kind only |
| Retention / churn signals | Cold opens, task lapses, serving duration | Foreground exposures, install-age bucket, effective UI context, Desk Mode/control/intent/link/notification rollups |
| Errors | Download/load bounded failure reasons; generation-refused enum currently unwired | Actual chat/server configuration/start notices, purchase failure and restore failure get numeric codes |

`external_client_connected` and `on_device_client_connected` are **request-action
counts**, not unique clients or socket connections: one successfully answered API
logged generation emits one event. HTTP 200 alone is insufficient: the engine must
produce a terminal stop/length outcome, and neither engine nor HTTP task may be
cancelled. This outcome is kept locally as `generationCompleted`; it transmits no
answer, token count or new payload property. Wire responses/statuses are unchanged.
Request-log updates are deduplicated by UUID in memory,
bounded to the current 200-row log. Currently successful generation routes write
this log; metadata successes such as `/api/tags` and `/v1/models` do not. No route
logging coverage is changed. Non-API, unfinished, failed and loopback requests do not
reach first value; unknown peers cannot reach it either. IPv4 127/8 and common
IPv6 loopback/mapped-loopback forms are excluded.

## New catalogue

All event names are snake_case. No new event accepts a free-form string.

| Event | Trigger | Event properties / bounded values | Latch |
| --- | --- | --- | --- |
| `app_foregrounded` | Root first appears, or returns active after background | None | Root view state excludes branch reappearance and inactive-only permission/control interruptions; not unique days |
| `screen_viewed` | Root appears or effective navigator screen changes; Privacy Details and routine results count actual view appearances from every entry point, with those routes excluded at Root | `screen`: onboarding, today, ask, routines, you, day, reminders, sleep, activity, routine_result, brain, add_brain, brain_advanced, devices, desk_mode, privacy, privacy_details, settings, instructions, diagnostics | No repeat on an unchanged effective navigator screen; one per appearance for the two locally presented details |
| `first_value_reached` | First successful external API request observed with sending permitted | `action=external_client`; `seconds_since_install`: nonnegative seconds | `pocketd.analytics.firstValueReached` in UserDefaults, written before emission |
| `feature_used` | Desk Mode entered; control/intent/notification/link arrival consumed | `feature`: desk_mode, control_ask, intent_ask, routine_notification, deep_link; `surface`: app, control, intent, notification, link | Existing arrival inbox consumption prevents replay |
| `paywall_viewed` | Pro sheet's first task, before offer/entitlement refresh | `trigger`: pro, laptop, routines, brains; `placement=sheet` | Per-presentation view state |
| `plan_selected` | Buy accepted after busy/product checks, before StoreKit purchase | `selected_plan=lifetime` | None; one product, no selection UI |
| `restore_started` | Restore accepted after its existing busy check, before sync | None | Existing busy guard retained |
| `restore_completed` | Restore returns | `outcome`: restored, empty, cancelled, failed; `error_code`: 0 for normal outcomes, bridged NSError code on throw | One per accepted restore; busy rejection emits nothing |
| `permission_prompted` | Existing ability/notification authorization call about to run | `permission`: calendar, reminders, health, notifications | Existing connect-trip coalescing retained |
| `permission_result` | Authorization attempt answers | Same permission; `outcome`: granted, denied, blocked, unavailable, failed, completed | None; Health `completed` never claims a read grant |
| `setting_changed` | Configuration assignment changes one tracked boolean | `setting`: authentication, reasoning, keep_awake; `enabled`: bool | Unchanged values emit nothing; records the persisted choice, not a successful server rebind |
| `share_used` | Clipboard copy succeeds | `kind`: address, diagnostics | None; contents never enter analytics |
| `error_shown` | Existing chat failure notice; purchase/restore/missing-price errors only from the Pro sheet's displayed status, using the same priority as its text; server error first exposed on Devices or Desk Mode, never merely created by a rebind | `area`: server, chat, purchase, restore; `error_code`: bridged NSError code, or local -1 unavailable/empty reply, -2 unverified purchase | One per displayed-error transition; a restore note hides a price failure; a promoted outcome without a sheet does not count as exposure; pending server code consumed on first active/topmost notice screen, excluding Ask/promo/Recent Requests covers |

The existing 33 event shapes remain in `AnalyticsEvent`: app opened, intro completed;
four model download outcomes, oversize override, two model-load outcomes; chat send;
server start/stop; external/on-device request; generation refused; ability
enabled/disabled/offer shown/accepted; scheduled task ran/lapsed; onboarding step;
brief generated/read aloud; voice ask; answer feedback; routine created; today tile;
five purchase outcomes. Their event-specific property names remain unchanged.

## Common context

| Property | Values / source |
| --- | --- |
| `install_env` | Existing synchronous receipt classification: debug, sandbox, app_store |
| `plan` | unknown, free, lifetime, early_supporter; only accepted StoreKit facts are published |
| `is_pro` | Boolean when plan is known; omitted for unknown, never false as a stand-in for uncertainty |
| `install_age_days` | day_0, days_1_6, days_7_29, days_30_89, days_90_plus; refreshed on every recorded event |
| `appearance` | light/dark from rendered SwiftUI environment; Desk Mode's fixed black surface is dark; unknown before a view supplies context |
| `dynamic_type` | standard through xxLarge, large for xxxLarge, accessibility for accessibility sizes; unknown before UI context |
| `notification_status` | unknown, not_determined, denied, authorized, provisional, ephemeral |
| `notifications_authorised` | Boolean when status is known; authorized/provisional/ephemeral are true; otherwise false; omitted while unknown |

No People properties or persistent SDK superproperties are added. Context is attached
to each event via the tested typed mapping, so unknown states cannot leave an old
SDK `is_pro` behind. Analytics-only plan revisions reject stale asynchronous scans
after purchase/restore invalidation; accepted verified results publish directly,
not via a SwiftUI `onChange`. Neither `hasChecked`, cached gate state, nor a failed
AppTransaction read is treated as verification. The lifetime product needs no
expiry polling. Entitlement decisions, gates, busy returns, transaction finishing,
purchase result handling and restore returns are unchanged.
StoreKit ownership gathering retains unverified rows as uncertainty for analytics,
while preserving the existing false access verdict. Verified purchase evidence
publishes lifetime, verified early app acquisition publishes early_supporter,
and free requires a completed scan with no unverified row and a verified app
transaction. A verified revocation/update is not a completed absence scan; unverified
live updates invalidate analytics (including older in-flight scans) without changing
the listener's access return or finishing behavior. Cancelled scans remain unknown,
including their early positive publication. The exact app-side StoreKit reducer
is compiled by the package tests via a symlink; PocketdKit itself gains no StoreKit
dependency.

Notification context is invalidated on foreground/request; overlapping older settings
reads cannot overwrite newer invalidation. Existing settings reads refresh it.
No additional awaited daemon lookup is inserted into a permission return or save.

## Known limits

- Install age starts with the first launch of this instrumentation. Existing
  installs are not retroactively dated; first value means first **observed eligible**
  external success, not a claim about all historical use. A preference backup/restore
  may preserve its date/latch beyond a fresh installation. Opt-out does not clear
  these analytics-only markers and opt-in does not replay declined actions.
- A process killed after the latch write but before SDK delivery may lose the
  first-value event; the latch favors at-most-once over resending. No server requests
  or their identifiers are persisted by this tracker.
- First value depends on the foreground log observer running. It cannot reconstruct
  evicted log rows or events from a dead process; successful metadata-only clients
  are not counted because those routes do not log successes. Streaming success follows the
  local terminal engine outcome plus final status, not token counts or answer inspection.
- Screen tracking covers the app's primary navigator and Ask sheet, not every local
  editor, history subpage, promotional overlay or Recent requests subnavigation.
  `deep_link` cannot truthfully distinguish widget taps from arbitrary links, so its
  surface is `link`, never an invented widget attribution. Existing intent/control
  inboxes are consumed in the phone process; no new App Group analytics relay is added.
- Permission events mean API **attempts/results**, not proof iOS displayed a modal.
  Notification status can stay unknown until an existing settings read returns;
  this is preferable to stale authorization. Debug raw-callback diagnostic paths
  are not production analytics paths. Voice permission attempts are not expanded.
  A lookup begun during an in-flight authorization request can temporarily capture
  its intermediate status; the next settings read refreshes it. Permission-result
  events report the API answer, not a guarantee that a concurrent status snapshot
  already reflects it.
- A cancelled/failed/pending purchase or failed restore can leave analytics plan
  unknown until a later accepted StoreKit result. Access remains unchanged. Local
  negative error codes are app sentinels, not StoreKit codes; numeric NSError codes
  are scoped by area, not localized text or arbitrary error-domain strings.
- `generation_refused` remains an unwired legacy case; the request log does not
  carry enough information to truthfully split thermal/battery/concurrency causes.

## Incremental volume and verification

Typical active use adds roughly 2–5 foregrounds, 5–20 primary screen changes,
0–3 arrival/Desk Mode rollups and 0–2 shares/settings/permission outcomes per day.
An actively serving phone adds one event per successfully logged generation request (often 5–50,
potentially much more); first value adds only one per eligible install. A paywall
visit adds one event; a buy adds plan selection plus existing purchase outcomes;
restore adds two events, with an additional error event on failure. Context fields
add no events. This is an estimate, not customer/revenue evidence or a cap forecast;
high-frequency clients can dominate volume and no throttling is introduced.

`ProductAnalyticsTests` runs in the existing `PocketdKitTests` target, exercising
the actual RequestLog update path, recorder context, consent/latch boundaries and
revision-guarded plan publication. `AnalyticsTaxonomyTests` samples all 46 cases.
Package tests require no simulator or inference SDK; the separate generic app
build verifies SwiftUI, StoreKit, notification and Mixpanel wiring compiles.
