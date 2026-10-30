// Disposable Sparkle integration harness. Never embedded in the production app.
import AppKit
import CryptoKit
import Foundation
import Sparkle

@MainActor
final class FixtureDriver: NSObject, SPUUserDriver {
    var retryTermination: (() -> Void)?
    let emit: (String, [String: Any]) -> Void
    init(emit: @escaping (String, [String: Any]) -> Void) { self.emit = emit }
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        emit("permission", [:])
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { emit("checking", [:]) }
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        emit("found", ["version": appcastItem.versionString, "displayVersion": appcastItem.displayVersionString])
        reply(.install)
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) { emit("notes-error", [:]) }
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        emit("not-found", errorFields(error)); acknowledgement(); finish()
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        emit("error", errorFields(error)); acknowledgement(); finish()
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { emit("downloading", [:]) }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() { emit("extracting", [:]) }
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        emit("ready", [:]); reply(.install)
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        retryTermination = retryTerminatingApplication
        emit("installing", ["applicationTerminated": applicationTerminated])
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        emit("installed", ["relaunched": relaunched]); acknowledgement(); finish()
    }
    func dismissUpdateInstallation() { emit("dismissed", [:]) }
    private func finish() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
    }
}

func errorFields(_ error: Error) -> [String: Any] {
    var chain: [[String: Any]] = []
    var item: NSError? = error as NSError
    while let current = item, chain.count < 8 {
        chain.append(["domain": current.domain, "code": current.code, "description": current.localizedDescription])
        item = current.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    return ["errors": chain]
}

@MainActor
final class FixtureApp: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {
    let root: URL
    let log: URL
    var updater: SPUUpdater?
    var driver: FixtureDriver?
    let version: String
    private var blockedTerminationOnce = false
    private var scenario: String { Bundle.main.object(forInfoDictionaryKey: "FixtureScenario") as? String ?? "valid" }
    init(root: URL, log: URL, version: String) { self.root = root; self.log = log; self.version = version }
    func emit(_ event: String, _ fields: [String: Any] = [:]) {
        var value = fields
        value["event"] = event; value["pid"] = getpid(); value["build"] = version
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
        let descriptor = open(log.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard descriptor >= 0 else { exit(93) }
        let line = data + Data([10])
        line.withUnsafeBytes { buffer in _ = write(descriptor, buffer.baseAddress, buffer.count) }
        close(descriptor)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        emit("started", ["bundle": Bundle.main.bundleURL.path])
        if version == "2" || version == "30" {
            emit("relaunched")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSApp.terminate(nil) }
            return
        }
        let driver = FixtureDriver { [weak self] event, fields in self?.emit(event, fields) }
        self.driver = driver
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        self.updater = updater
        do {
            try updater.start()
            updater.checkForUpdates()
        } catch { emit("configuration-error", errorFields(error)); NSApp.terminate(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 50) { [weak self] in
            self?.emit("timeout"); NSApp.terminate(nil)
        }
    }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock handler: @escaping () -> Void) -> Bool {
        guard ["deferred", "nfc-deferred"].contains(scenario) else { return false }
        emit("deferred")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.emit("deferred-held", self.installedBundleState())
            self.emit("installation-resumed")
            handler()
        }
        return true
    }
    private func installedBundleState() -> [String: Any] {
        let bundle = Bundle.main.bundleURL
        let data = try? Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))
        let info = data.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        return ["buildOnDisk": info?["CFBundleVersion"] as? String ?? "missing",
                "obsoleteExists": FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Contents/Resources/obsolete.txt").path),
                "newExists": FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Contents/Resources/new.txt").path)]
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if ["late-busy", "nfc-deferred"].contains(scenario) && !blockedTerminationOnce {
            blockedTerminationOnce = true
            emit("termination-blocked")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, let retry = self.driver?.retryTermination else { return }
                if self.scenario == "nfc-deferred" { self.emit("termination-held", self.installedBundleState()) }
                self.emit("termination-retried"); retry()
            }
            return .terminateCancel
        }
        emit("terminate"); return .terminateNow
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) { emit("aborted", errorFields(error)) }
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) { emit("will-relaunch") }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if let error { emit("cycle-error", errorFields(error)) }
    }
}

@main
struct UpdateFixture {
    @MainActor
    static func main() throws {
        let arguments = CommandLine.arguments
        if arguments.count == 4 && arguments[1] == "--generate-key" {
            let privateURL = URL(fileURLWithPath: arguments[2]).standardizedFileURL
            let publicURL = URL(fileURLWithPath: arguments[3]).standardizedFileURL
            guard privateURL.path.hasPrefix("/private/tmp/posle-updater-e2e-"),
                  publicURL.deletingLastPathComponent() == privateURL.deletingLastPathComponent() else { exit(90) }
            let key = Curve25519.Signing.PrivateKey()
            try key.rawRepresentation.base64EncodedData().write(to: privateURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateURL.path)
            try key.publicKey.rawRepresentation.base64EncodedData().write(to: publicURL, options: .atomic)
            return
        }
        let info = Bundle.main.infoDictionary ?? [:]
        guard let identifier = Bundle.main.bundleIdentifier, identifier.hasPrefix("app.posle.updaterfixture."),
              let rootPath = info["FixtureRoot"] as? String,
              rootPath.hasPrefix("/private/tmp/posle-updater-e2e-"),
              let logPath = info["FixtureLog"] as? String,
              let feedString = info["SUFeedURL"] as? String,
              let feed = URLComponents(string: feedString), feed.scheme == "http", feed.host == "127.0.0.1",
              let version = info["CFBundleVersion"] as? String else { exit(91) }
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL.resolvingSymlinksInPath()
        let log = URL(fileURLWithPath: logPath).standardizedFileURL.resolvingSymlinksInPath()
        let bundle = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        // Foundation may canonicalize an existing /private/tmp path to /tmp,
        // while keeping that prefix for a log file which does not exist yet.
        func comparable(_ url: URL) -> String {
            let path = url.path
            return path.hasPrefix("/private/tmp/") ? String(path.dropFirst(8)) : path
        }
        guard comparable(log).hasPrefix(comparable(root) + "/"),
              comparable(bundle).hasPrefix(comparable(root) + "/"),
              bundle.lastPathComponent == "UpdateFixture.app" else {
            fputs("Rejected fixture paths: root=\(root.path), log=\(log.path), bundle=\(bundle.path)\n", stderr)
            exit(92)
        }
        setenv("CFFIXED_USER_HOME", root.appendingPathComponent("home").path, 1)
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = FixtureApp(root: root, log: log, version: version)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
