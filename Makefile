.PHONY: test app lint clean

# The package is the part that CI can check in seconds without a simulator.
test:
	swift test

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

clean:
	rm -rf .build Pocketd.xcodeproj
