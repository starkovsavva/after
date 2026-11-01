import SwiftUI

struct CardsView: View {
    @EnvironmentObject private var store: AppStore
    var body: some View { CardsWorkspaceView(meetingID: store.selection, embedded: true) }
}
