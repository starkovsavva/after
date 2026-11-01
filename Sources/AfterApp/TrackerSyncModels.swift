import AfterLocalization
import Foundation

struct TrackerSyncConfiguration: Codable, Identifiable, Equatable {
    var id = ""
    var provider = "google"
    var folderID: String?
    var account = ""
    var organizationId = ""
    var cloudOrganization = false
    var iamToken = false
    var enabled = false
    var pushEnabled = false
    var paused = false
    var scopes: [String] = []
    var scopeTitles: [String: String] = [:]
    var expiresAt: Double?
    var statusMapping = ["todo": "open", "doing": "inProgress", "blocked": "paused", "done": "closed"]
    var lastSync: Double?
    var retryAt: Double?
    var error: String?
    var requiresAuth = false
    var revision = 0
    var providerTitle: String { provider == "google" ? "Google Tasks" : L("Яндекс Трекер") }
}
struct TrackerSyncScope: Decodable, Identifiable { var id: String; var title: String }
struct TrackerSyncConflict: Decodable, Identifiable {
    var id: String; var connection: String; var localId: String; var title: String
    var reason: String; var local: TrackerSyncFields?; var remote: TrackerSyncRemote; var fingerprint: String
}
struct TrackerSyncFields: Codable {
    var title: String; var text: String; var status: String; var due: String; var owner: String
}
struct TrackerSyncRemote: Decodable {
    var id: String; var scope: String; var revision: String; var fields: TrackerSyncFields; var deleted: Bool; var url: String
}
struct TrackerSyncPending: Decodable, Identifiable {
    var id: String; var connection: String; var localID: String; var title: String; var uncertain: Bool; var attempts: Int
}
struct TrackerSyncLink: Decodable { var connection: String; var localID: String; var scope: String; var remoteID: String; var url: String }
struct TrackerSyncState: Decodable {
    var linkedTasks: [TrackerSyncLink] = []
    var configurations: [TrackerSyncConfiguration] = []
    var conflicts: [TrackerSyncConflict] = []
    var pending: [TrackerSyncPending] = []
    var linkedCount = 0
}
