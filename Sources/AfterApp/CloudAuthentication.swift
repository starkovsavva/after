import AfterPlatform
import AfterPlatformMacOS
import AfterLocalization
import Foundation
import AfterCore

extension AppStore {
    /// Stop only this connection's subscription work before revoking its session.
    func disconnectChatGPTAccount(_ account: ChatGPTAccount) async {
        guard let accountID = account.profile?.id else { await account.signOut(); return }
        guard disconnectingChatGPTAccounts.insert(accountID).inserted else { return }
        defer { disconnectingChatGPTAccounts.remove(accountID) }
        if cloudCheckAccountID == accountID || knowledgeRebuildCloudAccountID == accountID {
            cancellationRequested = true
            runner.cancel(); cancelKnowledgeRebuildGeneration()
        }
        await jobs.cancelChatGPTAccount(accountID)
        guard account.profile?.id == accountID else { return }
        await account.signOut()
        cloudConnectionStatus = nil
    }

    /// The queued settings select the account; refreshed credentials never enter
    /// the durable queue, settings JSON, command arguments, or meeting library.
    func cloudCredential(for configuration: AppSettings) async throws -> String {
        if configuration.cloudProvider == "chatgpt" {
            guard !disconnectingChatGPTAccounts.contains(configuration.chatGPTAccountID) else {
                throw AppError.message(L("Выполняется выход из ChatGPT. Дождитесь завершения выхода."))
            }
            guard !isPreview else { throw AppError.message(L("В режиме предпросмотра вход в ChatGPT отключён.")) }
            guard !configuration.chatGPTAccountID.isEmpty else {
                throw AppError.message(L("Подключите подписку в настройках: Конспект и карточки → ChatGPT."))
            }
            guard !configuration.cloudModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AppError.message(L("Выберите доступную модель ChatGPT в настройках."))
            }
            return try await ChatGPTAccount.shared.accessToken(expectedAccountID: configuration.chatGPTAccountID)
        }
        guard !isPreview else { return "" }
        return try Keychain.readChecked(account: Keychain.account(for: configuration))
    }

    /// Actual requests propagate an inaccessible vault instead of treating it
    /// as a missing key. Previews and local speech never consult Keychain.
    func speechCredential(for configuration: AppSettings) throws -> String? {
        guard configuration.speechMode == "cloud", !isPreview else { return nil }
        return try Keychain.readChecked(account: Keychain.speechAccount(for: configuration))
    }
}
