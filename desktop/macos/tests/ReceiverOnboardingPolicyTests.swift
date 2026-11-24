import Foundation

@main
enum ReceiverOnboardingPolicyTests {
    static func main() {
        var count = 0
        func expect(_ value: Bool, _ message: String) {
            count += 1
            precondition(value, message)
        }
        let agent = ReceiverExtensionManifest(id: "app.sofatap.agent", name: "Sofatap Agent", executable: "SofatapAgent",
                                              permissions: [.screenRecording, .accessibility])
        expect(ReceiverOnboardingPolicy.required(extensions: []) == [.accessibility], "Free build asks only for Accessibility")
        expect(ReceiverOnboardingPolicy.required(extensions: [agent]) == [.accessibility, .screenRecording],
               "Extension permissions are added once, in a stable order")

        let both: [ReceiverPermission] = [.accessibility, .screenRecording]
        func step(_ granted: Set<ReceiverPermission>, intro: Bool = true, paired: Bool = false, onboarded: Bool = false,
                  dryRun: Bool = false, required: [ReceiverPermission] = both) -> ReceiverOnboardingStep {
            ReceiverOnboardingPolicy.step(required: required, granted: granted, introSeen: intro, paired: paired,
                                          onboarded: onboarded, dryRun: dryRun)
        }
        expect(step([], intro: false) == .intro, "First run opens on the introduction")
        expect(step([]) == .permission(.accessibility, index: 1, of: 2), "Accessibility comes first")
        expect(step([.accessibility]) == .permission(.screenRecording, index: 2, of: 2), "Then the extension's grant")
        expect(step([.accessibility, .screenRecording]) == .pair, "Pairing comes after every permission")
        expect(step([.accessibility, .screenRecording], paired: true) == .done, "A paired phone finishes onboarding")
        expect(step([], dryRun: true) == .pair, "Dry run never asks for permissions")
        expect(step([.accessibility, .screenRecording], onboarded: true) == .done, "Onboarded receivers stay in the menu bar")
        expect(step([.accessibility], onboarded: true) == .permission(.screenRecording, index: 2, of: 2), "A revoked grant comes back")
        expect(step([], intro: false, onboarded: true, required: [.accessibility]) == .permission(.accessibility, index: 1, of: 1),
               "Revoked Accessibility skips the introduction")

        let json = Data(#"{"id":"app.sofatap.agent","name":"Sofatap Agent","executable":"SofatapAgent","arguments":["--embedded"],"environment":{"CUA_DRIVER_EMBEDDED":"1"},"permissions":["accessibility","screenRecording","camera"]}"#.utf8)
        do {
            let manifest = try ReceiverExtensionManifest.decode(json)
            expect(manifest.permissions == [.accessibility, .screenRecording], "Unknown permissions are ignored")
            expect(manifest.arguments == ["--embedded"] && manifest.environment["CUA_DRIVER_EMBEDDED"] == "1", "Arguments and environment are kept")
        } catch { expect(false, "Valid manifest decodes: \(error)") }
        for bad in [#"{"id":"x","name":"x","executable":"../evil"}"#, #"{"id":"X Y","name":"x","executable":"a"}"#,
                    #"{"id":"x","name":"x","executable":"a","environment":{"DYLD_INSERT_LIBRARIES":"/tmp/x"}}"#] {
            expect((try? ReceiverExtensionManifest.decode(Data(bad.utf8))) == nil, "Rejects unsafe manifest \(bad)")
        }

        expect(ReceiverExtensionBackoff.delay(afterFailures: 0) == 1, "First restart after one second")
        expect(ReceiverExtensionBackoff.delay(afterFailures: 10) == 60, "Restarts cap at a minute")
        expect(ReceiverExtensionBackoff.failures(previous: 3, ranFor: 120) == 0, "A long run resets the backoff")
        expect(ReceiverExtensionBackoff.failures(previous: 3, ranFor: 2) == 4, "A quick exit counts as a failure")
        print("ReceiverOnboardingPolicyTests: \(count) checks passed")
    }
}
