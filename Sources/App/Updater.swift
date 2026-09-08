import Foundation
#if canImport(Sparkle)
import Sparkle
#endif

/// Keeps the app up to date on its own.
///
/// Silent by design: `SUAutomaticallyUpdate` and `SUEnableAutomaticChecks` in
/// the Info.plist mean Sparkle checks, downloads and installs without asking,
/// and without the first-launch permission prompt it otherwise shows. For an
/// agent app with no windows that is the only sensible behaviour — there is no
/// natural moment to interrupt someone who never looks at it.
///
/// Two things it still cannot do silently, which is macOS rather than Sparkle:
/// the app has to be writable by the user installing the update (true for a
/// normal drag to /Applications, false if it was copied there with `sudo`), and
/// the replacement is applied on relaunch rather than mid-flight.
@MainActor
final class Updater: NSObject, ObservableObject {
    /// A fork must not silently replace its custom code with an upstream release.
    let updatesEnabled: Bool

    init(updatesEnabled: Bool = Bundle.main.object(forInfoDictionaryKey: "CodenotchUpdatesEnabled") as? Bool ?? true) {
        #if canImport(Sparkle)
        self.updatesEnabled = updatesEnabled
        #else
        self.updatesEnabled = false
        #endif
        super.init()
    }

    /// What the last check came to, in words the settings sheet can show.
    ///
    /// Sparkle's own answer to a failed check is a modal saying "an error
    /// occurred in retrieving update information" — true, and useless: it names
    /// no cause and offers nothing to do. Keeping the outcome here lets the one
    /// place a user goes to think about updates say what actually happened.
    enum Outcome: Equatable {
        case idle
        case checking
        case upToDate(Date)
        case found(String)
        case unreachable
        case failed(String)

        var message: String? {
            switch self {
            case .idle:          return nil
            case .checking:      return "Checking…"
            case .upToDate:      return "Codenotch is up to date."
            case .found(let v):  return "Version \(v) is available and will install shortly."
            case .unreachable:
                // The one people actually hit, and the one Sparkle's wording
                // hides: nothing is wrong with the app or the machine.
                return "Couldn't reach the update server. Codenotch will try "
                     + "again on its own — nothing is wrong with this copy."
            case .failed(let why): return why
            }
        }
    }

    @Published private(set) var outcome: Outcome = .idle

    #if canImport(Sparkle)
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil
    )

    #endif

    /// Mirrors the preference, so switching it off really does stop the checks
    /// rather than only hiding them.
    var automatic: Bool {
        get {
            #if canImport(Sparkle)
            return updatesEnabled && controller.updater.automaticallyChecksForUpdates
            #else
            return false
            #endif
        }
        set {
            guard updatesEnabled else { return }
            #if canImport(Sparkle)
            controller.updater.automaticallyChecksForUpdates = newValue
            controller.updater.automaticallyDownloadsUpdates = newValue
            #endif
        }
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    var lastChecked: Date? {
        #if canImport(Sparkle)
        return updatesEnabled ? controller.updater.lastUpdateCheckDate : nil
        #else
        return nil
        #endif
    }

    /// Starts the scheduled checks. Deliberately not in `init`: the controller
    /// is lazy so that `self` exists before it is handed over as the delegate.
    func start() {
        guard updatesEnabled else { return }
        #if canImport(Sparkle)
        _ = controller
        #endif
    }

    /// The manual path, for someone who does not want to wait for the schedule.
    /// This one *does* show UI — it was asked for, so silence would read as a
    /// broken button.
    func checkNow() {
        guard updatesEnabled else { return }
        #if canImport(Sparkle)
        outcome = .checking
        controller.updater.checkForUpdates()
        #endif
    }

}

#if canImport(Sparkle)
extension Updater: SPUUpdaterDelegate {
    // MARK: - SPUUpdaterDelegate

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in self.outcome = .upToDate(Date()) }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor in self.outcome = .found(version) }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let code = (error as NSError).code
        Task { @MainActor in
            // A feed that cannot be fetched is the ordinary failure — offline,
            // or the server is down — and it is not the user's problem to
            // solve. Anything else is reported as itself.
            self.outcome = Self.isUnreachable(code)
                ? .unreachable
                : .failed(error.localizedDescription)
        }
    }

    /// Sparkle folds every "could not load the feed" case into one code.
    static func isUnreachable(_ code: Int) -> Bool {
        code == Int(SUError.appcastError.rawValue)
    }
}

#endif
