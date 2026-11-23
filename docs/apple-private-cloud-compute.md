# Testing Apple Private Cloud Compute

On an eligible iPhone, select **Apple Private Cloud Compute** on the onboarding brain screen or under **You → Brain**. Ask a fresh question, such as “What is 17 plus 8?”, then reopen **You → Brain** to see the saved selection. Choosing **Built into iPhone** or a downloaded brain switches back to local processing. A paired laptop always uses a downloaded brain.

The cloud option requires **iOS 27 or later**, a device and region where Apple Intelligence supports PCC, an internet connection for requests, and an app signed for PCC. There is no device-name allowlist. Apple reports whether the service is ready and whether the person's daily quota is approaching its limit or exhausted; a reset date is shown when Apple supplies one. Quota or connectivity failures do not silently replay a request through another model.

## Sign a build that can make a real request

1. Enable Apple's managed **Access to models on Private Cloud Compute** capability on the app's explicit App ID. Use a current development or distribution profile that authorizes `com.apple.developer.private-cloud-compute`.
2. Run `make app`, then build the **Pocketd** scheme on a supported iPhone using the normal app entitlements. `make device-install-pcc DEVICE=<device-id>` performs the signature check before installing. The existing `make device-install` intentionally uses minimal, local-only entitlements.
3. Check an archive or an exported, signed app before testing or distributing it: `make verify-pcc-signing APP=/path/to/Pocketd.xcarchive`. For an exported IPA, run the same check on the unzipped `Payload/Pocketd.app`. This verifies the app's actual signature, the build's signing receipt, and the embedded profile if present. A source entitlement or a simulator reporting `.available` alone is not proof of authorization.

For a live test, leave Xcode's simulated model and quota overrides off, select the cloud option yourself, and get a nonempty answer in Ask. Ordinary unsigned/ad-hoc simulators and local-only builds do not send questions to Apple PCC. Simulator UI tests cover selection, persistence, availability and failure states with a separate Debug-only test transport.

[Apple's entitlement and eligibility](https://developer.apple.com/private-cloud-compute/) · [Availability and authentication](https://developer.apple.com/documentation/foundationmodels/detecting-available-apple-foundation-models) · [Requests and quota handling](https://developer.apple.com/documentation/foundationmodels/adding-server-side-intelligence-with-private-cloud-compute)
