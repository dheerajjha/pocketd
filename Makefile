.PHONY: test verify app build-sim smoke catalogue device-install clean

# The package is the part that CI can check in seconds without a simulator.
test:
	swift test

# What "it builds" actually means. `make app` is xcodegen and NOTHING else — it
# regenerates the project file and compiles not one line — so a green `make app`
# says only that project.yml parsed.
#
# That gap hid two compile errors in the app target for three commits: an
# optional enum argument that @ToolArguments cannot expand, and a `Self`
# reference in a stored property initializer. Both were invisible to `swift
# test`, because neither file is in the package, and invisible to `make app`,
# because it does not build. Use this before claiming the app builds.
verify: test build-sim

# Regenerates Pocketd.xcodeproj from project.yml. Needed after any change to the
# spec, and after a fresh clone.
app:
	xcodegen generate

# Builds the app for a simulator, which is the cheapest way to catch a break in
# the app target. Note that llama.cpp runs on the simulator's CPU, so it is fine
# for checking that things compile and the UI works, and useless for measuring
# tokens per second.
# -skipMacroValidation: LocalLLMClient ships a Swift macro plugin, and Xcode
# refuses to run one from a package until a human clicks Trust & Enable. That
# prompt cannot appear in a headless build, so a command-line build has to opt
# in explicitly.
build-sim: app
	xcodebuild -project Pocketd.xcodeproj -scheme Pocketd \
		-destination 'generic/platform=iOS Simulator' \
		-derivedDataPath .build/xcode \
		-skipMacroValidation \
		CODE_SIGNING_ALLOWED=NO build

# Exercises a RUNNING pocketd the way a client would — a real model on a real
# device over a real network hop, which is exactly what the package tests
# cannot cover. Read the base URL and key off the app's Server tab.
#   make smoke BASE=http://192.168.1.42:11434 KEY=pk-...
BASE ?= http://127.0.0.1:11434
KEY  ?=
smoke:
	./scripts/smoke.sh $(BASE) $(KEY)

# Installs on a physical device. Two overrides are usually needed on a machine
# whose developer account has not enabled the Increased Memory Limit capability
# for this App ID: a bundle identifier that already has a provisioning profile,
# and an empty entitlements file. The app reads the entitlement at runtime, so
# a build without it reports the smaller memory budget honestly rather than
# recommending models the device cannot hold.
#
#   make device-install DEVICE=<udid> BUNDLE_ID=<id from an existing profile>
DEVICE ?=
BUNDLE_ID ?=
# BUNDLE_ID sets POCKETD_BUNDLE_ID, not PRODUCT_BUNDLE_IDENTIFIER.
#
# Settings on an xcodebuild command line apply to EVERY target in the graph, so
# overriding PRODUCT_BUNDLE_IDENTIFIER directly would build the app and its
# widget extension as the same identifier. An extension's must be prefixed by
# its host's and must differ from it; the build fails with "Embedded binary's
# bundle identifier is not prefixed with the parent app's", naming neither
# target. The project defines PRODUCT_BUNDLE_IDENTIFIER for both in terms of
# POCKETD_BUNDLE_ID, so moving that one variable moves both and keeps the
# nesting. Same trick, and same reason, as POCKETD_ENTITLEMENTS below.
device-install: app
	xcodebuild -project Pocketd.xcodeproj -scheme Pocketd \
		-destination 'platform=iOS,id=$(DEVICE)' \
		-derivedDataPath .build/device -skipMacroValidation \
		-allowProvisioningUpdates \
		$(if $(BUNDLE_ID),POCKETD_BUNDLE_ID=$(BUNDLE_ID),) \
		POCKETD_ENTITLEMENTS='$(PWD)/App/Resources/Pocketd-NoMemoryLimit.entitlements' \
		build
	xcrun devicectl device install app --device $(DEVICE) \
		.build/device/Build/Products/Debug-iphoneos/Pocketd.app

# Two catalogue entries answered 401 and 404 for weeks — the first two rows of
# the list, so the first thing a new user tapped always failed. Nothing in the
# build could see it.
catalogue:
	./scripts/verify-catalogue.sh

clean:
	rm -rf .build Pocketd.xcodeproj
