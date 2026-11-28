import StoreKit
import SwiftUI

@main
struct SofaTapApp: App {
    @StateObject private var controller = ControllerModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RemoteView(model: controller)
                .preferredColorScheme(.dark)
                .tint(Palette.mint)
                .modifier(ReviewPromptHost(model: controller))
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { controller.becameActive() }
                    else if phase == .background { controller.becameInactive() }
                    else { controller.pauseInput() }
                }
        }
    }
}

/// Tracks real computer sessions and asks iOS for the rating prompt only when
/// the app returns to the foreground with no session running, so it never
/// interrupts someone using the remote. See ReviewPromptPolicy.
private struct ReviewPromptHost: ViewModifier {
    @ObservedObject var model: ControllerModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.requestReview) private var requestReview
    @State private var sessionStart: Date?
    private let policy = ReviewPromptPolicy()

    func body(content: Content) -> some View {
        content
            .onAppear { policy.noteLaunch(now: Date()) }
            .onChange(of: model.connected && model.inputAvailable) { _, usable in
                if usable && !model.demo { sessionStart = sessionStart ?? Date() }
                else { endSession() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { endSession() }
                else if phase == .active { consider() }
            }
    }

    private func endSession() {
        guard let start = sessionStart else { return }
        sessionStart = nil
        policy.recordSession(start: start, end: Date())
    }

    private func consider() {
        guard !model.demo, sessionStart == nil, !model.connected else { return }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        guard policy.shouldRequest(now: Date(), version: version) else { return }
        policy.markRequested(version: version)
        requestReview()
    }
}

enum Palette {
    static let background = Color(red: 0.039, green: 0.051, blue: 0.067)
    static let panel = Color(red: 0.079, green: 0.098, blue: 0.122)
    static let elevated = Color(red: 0.110, green: 0.137, blue: 0.165)
    static let mint = Color(red: 0.722, green: 0.953, blue: 0.816)
    static let muted = Color(red: 0.60, green: 0.65, blue: 0.69)
}
