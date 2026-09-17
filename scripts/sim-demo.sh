#!/usr/bin/env bash
# Launches Pocketd on a simulator with a seeded calendar and reminders list,
# for screenshots and UI testing that need something believable on screen
# without a real phone anywhere in the room. `unseed` reverses it.
#
# Erases nothing on the simulator and grants nothing beyond the two privacy
# switches the seed itself needs — an existing install, its models and its
# conversations are left exactly as they were. Nothing this triggers touches
# the simulator's own default calendar or reminders list either: every event
# and reminder this seeds lands in its own "Pocketd Demo" calendar and list,
# found-or-created the first time `seed` runs and removed outright by
# `unseed` — never mixed into whatever the simulator already had. The
# seeding and unseeding both live in App/Sources/Diagnostics/DemoSeed.swift,
# entirely inside `#if DEBUG`, and the launch arguments below only do
# anything on a Debug build: there is no code path through any of this in a
# Release/App Store build, so running this script against one launches the
# app normally and touches nothing.
#
#   scripts/sim-demo.sh <simulator-udid> [seed|unseed]
#
# `seed` is the default when the mode is left off. Build and install a Debug
# build first, e.g. `make build-sim` or the shared build-sim.sh helper, then
# run this against the same udid.
#
# The same launch arguments work unmodified on a physical phone — there is
# just no `simctl privacy` there to grant access for you first, and no
# `simctl launch` to start the app. The nearest equivalent, verified against
# `xcrun devicectl device process launch --help` on this machine (devicectl
# 642.16):
#
#   xcrun devicectl device process launch --device <udid> \
#       dev.pocketd.app -- -pocketd.seedDemo -pocketd.skipIntro
#
# Two things about that command that are easy to get wrong:
#   - The `--` before the app's own arguments is required, not decorative.
#     Without it, devicectl's own argument parser tries to consume
#     `-pocketd.seedDemo` itself and fails with an unrelated-looking error
#     about a missing `-t <seconds>` value.
#   - There is no `--start-stopped=false`. `--start-stopped` takes no value
#     at all — passing one is a parse error — and it means the opposite of
#     what the name suggests it might: present, it launches the app
#     suspended, waiting for a debugger to attach; the normal running launch
#     this script wants is what you get by leaving the flag off entirely.
# Swap `-pocketd.seedDemo -pocketd.skipIntro` for `-pocketd.unseedDemo` to
# remove the demo calendar and list from a phone the same way.
#
# A human has to grant Calendars and Reminders access to Pocketd once first,
# the ordinary way through Settings — there is no `simctl privacy` for a
# physical device, and no one there to tap the system prompt on the app's
# own first attempt to ask.
set -u
UDID="${1:?usage: sim-demo.sh <simulator-udid> [seed|unseed]}"
MODE="${2:-seed}"
BUNDLE_ID="dev.pocketd.app"

case "$MODE" in
    seed)   ARG="-pocketd.seedDemo" ;;
    unseed) ARG="-pocketd.unseedDemo" ;;
    *)
        echo "usage: sim-demo.sh <simulator-udid> [seed|unseed]" >&2
        exit 1
        ;;
esac

# Full access, not the default prompt a fresh install would show — a
# screenshot run has no one there to tap Allow. `DemoSeed` checks and
# requests again at seed/unseed time regardless, and would otherwise find the
# permission undetermined and get nothing back synchronously enough for the
# first screen to show data.
xcrun simctl privacy "$UDID" grant calendar "$BUNDLE_ID"
xcrun simctl privacy "$UDID" grant reminders "$BUNDLE_ID"

if [ "$MODE" = "seed" ]; then
    xcrun simctl launch "$UDID" "$BUNDLE_ID" "$ARG" -pocketd.skipIntro
else
    xcrun simctl launch "$UDID" "$BUNDLE_ID" "$ARG"
fi
