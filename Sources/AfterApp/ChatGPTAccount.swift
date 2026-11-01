import AfterPlatform
import AfterPlatformMacOS
import AfterLocalization
import AppKit
import Combine
import Foundation

/// Only an explicit settings action opens the browser. Production credentials never enter
/// previews, the meeting library, authorization logs, or another application's auth store.
@MainActor
final class ChatGPTAccount: ObservableObject {
    static let shared = ChatGPTAccount()
    @Published private(set) var profile: ChatGPTProfile?
    @Published private(set) var savedProfiles: [ChatGPTProfile] = []
    @Published private(set) var models: [ChatGPTModel] = []
    @Published private(set) var isConnecting = false
    @Published private(set) var isLoadingModels = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var isSigningOut = false
    @Published private(set) var message: String?
    @Published private(set) var isError = false
    private let engine: ChatGPTSessionStore
    private let disabled: Bool
    private let browserOpener: @MainActor @Sendable (URL) -> Bool
    private var loginTask: Task<ChatGPTSessionStore.Snapshot, Error>?
    private var initialRestoreTask: Task<ChatGPTSessionStore.Snapshot, Error>?
    private var initialRestoreFailure: Error?
    private var initialRestoreRevision: UUID?
    private var revision = UUID()
    private var catalogRevision = UUID()
    private var refreshCount = 0

    convenience init(preview: Bool = false) {
        let arguments = ProcessInfo.processInfo.arguments
        let disabled = preview || arguments.contains("--preview") || arguments.contains("--snapshot") || arguments.contains { $0.hasPrefix("--check-") }
        let engine = ChatGPTSessionStore(callbackPage: ChatGPTCallbackPage.content)
        let restore: Task<ChatGPTSessionStore.Snapshot, Error>? = disabled ? nil : Task { try await engine.snapshot() }
        self.init(engine: engine, disabled: disabled, restore: restore)
    }
    private init(engine: ChatGPTSessionStore, disabled: Bool, restore: Task<ChatGPTSessionStore.Snapshot, Error>?,
                 browserOpener: @escaping @MainActor @Sendable (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.engine = engine; self.disabled = disabled; self.browserOpener = browserOpener; initialRestoreTask = restore
        initialRestoreRevision = revision
        if restore != nil { Task { [weak self] in try? await self?.restoreInitialSession() } }
    }
    /// Every startup caller awaits the same read. A cancelled job does not cancel
    /// restoration for the UI or other jobs; an explicit sign-in/out supersedes it.
    private func restoreInitialSession() async throws {
        try Task.checkCancellation()
        guard revision == initialRestoreRevision else { return }
        guard let pending = initialRestoreTask else {
            if let initialRestoreFailure { throw initialRestoreFailure }
            return
        }
        do {
            let snapshot = try await pending.value
            try Task.checkCancellation()
            guard initialRestoreTask != nil else { return }
            initialRestoreTask = nil
            if revision == initialRestoreRevision { apply(snapshot) }
        } catch is CancellationError { throw CancellationError() }
        catch {
            if initialRestoreTask != nil {
                initialRestoreTask = nil; initialRestoreFailure = error
                if revision == initialRestoreRevision { report(error) }
            }
            throw error
        }
    }
    func signIn(useDifferentAccount: Bool = false) async {
        do { try await restoreInitialSession() } catch is CancellationError { return } catch {}
        await connect(accountID: useDifferentAccount ? nil : profile?.id)
    }
    func signIn(accountID: String) async {
        do { try await restoreInitialSession() } catch is CancellationError { return } catch {}
        await connect(accountID: accountID)
    }
    private func connect(accountID: String?) async {
        guard !disabled, !isConnecting, !isSigningOut, !Task.isCancelled else { return }
        let operationID = UUID(); revision = operationID
        isConnecting = true; message = nil; isError = false
        let engine = self.engine, browserOpener = self.browserOpener
        let originWindow = NSApp.keyWindow ?? NSApp.mainWindow?.attachedSheet ?? NSApp.mainWindow
        let handoff = ChatGPTLoginHandoff(operationID: operationID, currentOperation: { [weak self] in
            guard let self, !self.disabled, self.isConnecting, !self.isSigningOut, !Task.isCancelled else { return nil }
            return self.revision
        }, activate: { [weak originWindow] in
            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
            guard let originWindow else { return }
            let parent = originWindow.sheetParent ?? originWindow
            if parent.isMiniaturized { parent.deminiaturize(nil) }
            parent.makeKeyAndOrderFront(nil)
            (parent.attachedSheet ?? originWindow).makeKeyAndOrderFront(nil)
        })
        let operation = Task {
            try await engine.signIn(accountID: accountID, openBrowser: browserOpener,
                                    callbackReceived: { handoff.receivedCallback() })
        }
        loginTask = operation
        do {
            let snapshot = try await operation.value
            guard revision == operationID else { return }
            apply(snapshot)
            message = profile?.planEnabled == true ? L("ChatGPT подключён") : L("Вход выполнен. Разреши приложению использовать подписку ChatGPT.")
            handoff.finished()
        } catch {
            guard revision == operationID else { return }
            if !(error is CancellationError) { report(error); handoff.finished() }
        }
        guard revision == operationID else { return }
        loginTask = nil; isConnecting = false
        if profile?.planEnabled == true { await refreshModels() }
    }
    func cancelSignIn() { revision = UUID(); loginTask?.cancel(); loginTask = nil; isConnecting = false }
    func signOut() async {
        guard !disabled, !isSigningOut else { return }
        isSigningOut = true
        defer { isSigningOut = false }
        cancelSignIn(); catalogRevision = UUID(); models = []; isLoadingModels = false
        profile = nil
        do {
            let result = try await engine.signOut()
            apply(result.snapshot)
            message = result.remoteRevoked ? L("Выход выполнен") : L("Выход выполнен на этом Mac. Отозвать доступ также можно в настройках ChatGPT.")
            isError = !result.remoteRevoked
        } catch { report(error) }
    }
    func refreshModels() async {
        guard !disabled else { return }
        do { try await restoreInitialSession() } catch { return }
        guard !isSigningOut, let accountID = profile?.id, profile?.planEnabled == true else { models = []; return }
        let operationID = UUID(); catalogRevision = operationID
        isLoadingModels = true; message = nil; isError = false
        defer { if catalogRevision == operationID { isLoadingModels = false } }
        do {
            let catalog = try await engine.models(expectedAccountID: accountID)
            try Task.checkCancellation()
            guard catalogRevision == operationID, profile?.id == accountID else { return }
            models = catalog
            if catalog.isEmpty { message = L("Для этого аккаунта пока нет доступных моделей"); isError = false }
        } catch {
            // Closing settings cancels its catalog task, not the connected account
            // or the model the user already selected.
            guard !(error is CancellationError), !Task.isCancelled,
                  catalogRevision == operationID, profile?.id == accountID else { return }
            models = []
            if let snapshot = try? await engine.snapshot() { apply(snapshot) }
            report(error)
        }
    }
    func accessToken(expectedAccountID: String) async throws -> String {
        guard !disabled else { throw ChatGPTSignInError.accountChanged }
        try await restoreInitialSession()
        guard !isSigningOut, profile?.id == expectedAccountID else { throw ChatGPTSignInError.accountChanged }
        refreshCount += 1; isRefreshing = true
        defer { refreshCount -= 1; isRefreshing = refreshCount > 0 }
        do {
            let token = try await engine.accessToken(expectedAccountID: expectedAccountID)
            guard profile?.id == expectedAccountID else { throw ChatGPTSignInError.accountChanged }
            return token
        } catch is CancellationError { throw CancellationError() }
        catch {
            if let snapshot = try? await engine.snapshot() { apply(snapshot) }
            report(error); throw error
        }
    }
    private func apply(_ snapshot: ChatGPTSessionStore.Snapshot) {
        if profile?.id != snapshot.active?.id || snapshot.active?.planEnabled != true { models = [] }
        profile = snapshot.active; savedProfiles = snapshot.profiles
    }
    private func report(_ error: Error) {
        isError = true
        message = (error as? ChatGPTSignInError)?.errorDescription ?? L("Не удалось подключиться к ChatGPT. Проверь сеть и попробуй ещё раз.")
    }
    #if DEBUG
    static func verifyCancelledCatalog() async throws {
        let previous = [ChatGPTModel(id: "offline-selected", name: "Selected model", supportedReasoning: nil)]
        for urlSessionCancellation in [false, true] {
            let fixture = try ChatGPTSessionStore.startupFixture(modelRequest: { _ in
                // Mimic a request cancelled as settings disappear. No URLSession
                // or live credentials are reached, including on test failure.
                withUnsafeCurrentTask { $0?.cancel() }
                if urlSessionCancellation { throw URLError(.cancelled) }
                throw CancellationError()
            })
            let directRequest = Task { try await fixture.engine.models(expectedAccountID: fixture.id) }
            do { _ = try await directRequest.value; throw ChatGPTSignInError.identity }
            catch is CancellationError {}
            let account = ChatGPTAccount(engine: fixture.engine, disabled: false, restore: nil,
                                         browserOpener: { _ in false })
            account.apply(try await fixture.engine.snapshot()); account.models = previous
            let request = Task { await account.refreshModels() }
            await request.value
            guard account.profile?.id == fixture.id, account.models == previous,
                  !account.isLoadingModels, !account.isError, account.message == nil else {
                throw ChatGPTSignInError.identity
            }
        }
    }
    static func verifyCancelledSignIn() async throws {
        let fixture = try ChatGPTSessionStore.startupFixture()
        var browserCalls = 0
        let account = ChatGPTAccount(engine: fixture.engine, disabled: false, restore: nil, browserOpener: { _ in
            browserCalls += 1
            return false // Even a regression cannot open a browser or reach an account.
        })
        account.apply(try await fixture.engine.snapshot())
        for newAccount in [false, true] {
            let cancelled = Task {
                if newAccount { await account.signIn(useDifferentAccount: true) }
                else { await account.signIn(accountID: fixture.id) }
            }
            cancelled.cancel(); await cancelled.value
            guard browserCalls == 0, account.profile?.id == fixture.id, !account.isConnecting,
                  account.message == nil else { throw ChatGPTSignInError.callback }
        }
    }
    static func verifyLoginHandoff() throws {
        let ownID = UUID()
        var current: UUID? = ownID
        var activations = 0
        let handoff = ChatGPTLoginHandoff(operationID: ownID, currentOperation: { current }, activate: { activations += 1 })
        handoff.finished()
        guard activations == 0 else { throw ChatGPTSignInError.callback }
        handoff.receivedCallback()
        handoff.finished()
        guard activations == 2 else { throw ChatGPTSignInError.callback }
        current = nil // cancellation, preview, sign-out or a closed settings view
        handoff.receivedCallback(); handoff.finished()
        guard activations == 2 else { throw ChatGPTSignInError.callback }
        current = UUID() // a newer login owns the settings window
        handoff.receivedCallback(); handoff.finished()
        guard activations == 2 else { throw ChatGPTSignInError.callback }
        current = ownID
        let errorHandoff = ChatGPTLoginHandoff(operationID: ownID, currentOperation: { current }, activate: { activations += 1 })
        errorHandoff.receivedCallback(); errorHandoff.finished()
        guard activations == 4 else { throw ChatGPTSignInError.callback }
    }
    static func restoringFixture() throws -> (account: ChatGPTAccount, id: String) {
        let fixture = try ChatGPTSessionStore.startupFixture()
        let restore = Task {
            try await Task.sleep(for: .milliseconds(35))
            return try await fixture.engine.snapshot()
        }
        return (ChatGPTAccount(engine: fixture.engine, disabled: false, restore: restore), fixture.id)
    }
    static func fixture(profile: ChatGPTProfile? = nil, savedProfiles: [ChatGPTProfile] = [], models: [ChatGPTModel] = [], connecting: Bool = false, loading: Bool = false, message: String? = nil, isError: Bool = false) -> ChatGPTAccount {
        let result = ChatGPTAccount(preview: true)
        result.profile = profile; result.savedProfiles = savedProfiles; result.models = models
        result.isConnecting = connecting; result.isLoadingModels = loading; result.message = message; result.isError = isError
        return result
    }
    #endif
}

@MainActor
private final class ChatGPTLoginHandoff {
    private let operationID: UUID
    private let currentOperation: () -> UUID?
    private let activate: () -> Void
    private var received = false
    init(operationID: UUID, currentOperation: @escaping () -> UUID?, activate: @escaping () -> Void) {
        self.operationID = operationID; self.currentOperation = currentOperation; self.activate = activate
    }
    func receivedCallback() {
        guard currentOperation() == operationID else { return }
        received = true; activate()
    }
    func finished() {
        guard received, currentOperation() == operationID else { return }
        activate()
    }
}
