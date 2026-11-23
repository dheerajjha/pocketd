# Testing Apple Private Cloud Compute

On an eligible iPhone, select **Apple Private Cloud Compute** on the onboarding brain screen or under **You → Brain**. Ask a fresh question, such as “What is 17 plus 8?”, then reopen **You → Brain** to see the saved selection. Choosing **Built into iPhone** or a downloaded brain switches back to local processing. A paired laptop always uses a downloaded brain.

The cloud option requires **iOS 27 or later**, a device and region where Apple Intelligence supports PCC, an internet connection for requests, and an app signed for PCC. There is no device-name allowlist. Apple reports whether the service is ready and whether the person's daily quota is approaching its limit or exhausted; a reset date is shown when Apple supplies one. Quota or connectivity failures do not silently replay a request through another model.

## Sign a build that can make a real request

1. Enable Apple's managed **Access to models on Private Cloud Compute** capability on the app's explicit App ID. Use a current development or distribution profile that authorizes `com.apple.developer.private-cloud-compute`.
2. Run `make app`, then build the **Pocketd** scheme on a supported iPhone using the normal app entitlements. `make device-install-pcc DEVICE=<device-id>` performs the signature check before installing. The existing `make device-install` intentionally uses minimal, local-only entitlements.
3. Check an archive or an exported, signed app before testing or distributing it: `make verify-pcc-signing APP=/path/to/Pocketd.xcarchive`. For an exported IPA, run the same check on the unzipped `Payload/Pocketd.app`. This verifies the app's actual signature, the build's signing receipt, and the embedded profile if present. A source entitlement or a simulator reporting `.available` alone is not proof of authorization.

For a live test, leave Xcode's simulated model and quota overrides off. Select the cloud option yourself, open Ask, and look for **Apple Private Cloud Compute** above the conversation before sending a fresh question. Development IPAs install on devices included in the signing profile.

For repeatable UI checks, run the manual [**Private Cloud Compute UI** workflow](https://github.com/dheerajjha/pocketd/actions/workflows/pcc-ui.yml). It tests both pickers, persisted choices, an older Shortcut, quota and connectivity with a labelled simulator fixture. A separate simulator starts with real offline GGUF weights to check switching back to a downloaded model. Each suite retains its XCTest result; the combined artifact contains the counts and three screenshots. Fixture replies do not use Apple's service or consume quota.

For transport diagnostics only, an entitled Debug build can be compiled with `-D POCKETD_LIVE_PCC_PROBE` and launched with `-pocketd.verifyLivePCC <new UUID>`. That build starts a separate diagnostic entry point, sends at most one synthetic question without personal tools, and records the native model binding and result in `Library/Application Support/PCCLiveQA`. It does not open your chat history or change your saved brain.

[Apple's entitlement and eligibility](https://developer.apple.com/private-cloud-compute/) · [Availability and authentication](https://developer.apple.com/documentation/foundationmodels/detecting-available-apple-foundation-models) · [Requests and quota handling](https://developer.apple.com/documentation/foundationmodels/adding-server-side-intelligence-with-private-cloud-compute)
