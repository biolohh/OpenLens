import AppIntents

// App Shortcuts show up in Spotlight when someone searches for OpenLens, and in Siri and the
// Shortcuts app. Shipped phrases and intent type names are a public contract: saved shortcuts
// and voice commands depend on them, so add new ones instead of renaming or removing these.

struct OpenLensShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NewSessionIntent(),
            phrases: [
                "Start a new session in \(.applicationName)",
                "New \(.applicationName) session",
                "Create a session in \(.applicationName)"
            ],
            shortTitle: "New Session",
            systemImageName: "plus.bubble"
        )
    }
}

/// Asks for a name, then opens OpenLens and starts a new chat session with it in the current
/// workspace. The app creates the session once it's connected, so this also works when the
/// intent launches the app cold.
struct NewSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "New Session"
    static let description = IntentDescription("Asks for a name, then opens OpenLens and starts a new chat session.")
    // The system resolves `name` before switching to the app, so the prompt appears in
    // Spotlight or Siri first.
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }
    // iOS 18 fallback for `supportedModes` (ios18 branch): open the app after the
    // parameter is resolved. Ignored on iOS 26, where `supportedModes` wins.
    static let openAppWhenRun: Bool = true

    static var parameterSummary: some ParameterSummary {
        Summary("Start a new session named \(\.$name)")
    }

    @Parameter(title: "Name", requestValueDialog: "What should the session be called?")
    var name: String

    @Dependency private var pendingActions: PendingAppActions

    func perform() async throws -> some IntentResult {
        await pendingActions.requestNewSession(title: name)
        return .result()
    }
}
