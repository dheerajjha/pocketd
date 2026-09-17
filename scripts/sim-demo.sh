#!/usr/bin/env bash
# Launches Pocketd on a simulator with a seeded calendar and reminders list,
# for screenshots and UI testing that need something believable on screen
# without a real phone anywhere in the room.
#
# Erases nothing on the simulator and grants nothing beyond the two privacy
# switches the seed itself needs — an existing install, its models and its
# conversations are left exactly as they were. The seeding this triggers
# lives in App/Sources/Diagnostics/DemoSeed.swift, entirely inside `#if DEBUG`,
# and the launch arguments below only do anything on a Debug build: there is
# no code path through any of this in a Release/App Store build, so running
# this script against one launches the app normally and seeds nothing.
#
#   scripts/sim-demo.sh <simulator-udid>
#
# Build and install a Debug build first, e.g. `make build-sim` or the shared
# build-sim.sh helper, then run this against the same udid.
set -u
UDID="${1:?usage: sim-demo.sh <simulator-udid>}"
BUNDLE_ID="dev.pocketd.app"

# Full access, not the default prompt a fresh install would show — a
# screenshot run has no one there to tap Allow. `EventAccess.requestReadAccess`
# still runs at seed time and would otherwise find the permission undetermined
# and get nothing back synchronously enough for the first screen to show data.
xcrun simctl privacy "$UDID" grant calendar "$BUNDLE_ID"
xcrun simctl privacy "$UDID" grant reminders "$BUNDLE_ID"

xcrun simctl launch "$UDID" "$BUNDLE_ID" -pocketd.seedDemo -pocketd.skipIntro
