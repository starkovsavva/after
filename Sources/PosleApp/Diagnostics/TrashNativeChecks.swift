#if DEBUG
import AppKit
import Foundation
import PosleCore
import SwiftUI

@MainActor enum TrashNativeChecks {
    static func run() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--preview"), let path = ProcessInfo.processInfo.environment["POSLE_DATA_DIR"] else { throw AppError.message("Disposable fixture required") }
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        try expect(["/tmp", "/private/tmp"].contains(root.deletingLastPathComponent().path) && root.lastPathComponent.hasPrefix("posle-native-check-"), "Disposable root required")
        let app = AppStore(preview: true), bridge = try RustBridge.shared.get()
        let meeting = Meeting(title: "Английский · разговор с преподавателем", source: "source.wav", status: "ready")
        let directory = app.meetingDirectory(meeting.id)
        try app.write(meeting, directory.appendingPathComponent("meta.json"))
        try Data("synthetic audio fixture".utf8).write(to: directory.appendingPathComponent("source.wav"))
        let summary: [String: Any] = ["overview": "Договорились повторить рабочие выражения", "items": [], "cards": [["id":"card-next-step", "kind":"phrase", "front":"Договориться о следующем шаге", "back":"Agree on the next step", "context":"Рабочая встреча", "segmentIDs":[]]]]
        _ = try bridge.request(root: root, command: "write", arguments: ["path":"meetings/\(meeting.id)/summary.json", "value":summary])
        guard let note = app.notes.capture(text: "Подготовить вопросы к ревью") else { throw AppError.message(app.notes.error ?? "Note fixture failed") }
        app.notes.delete(note)
        app.reloadLibrary(); app.openMeeting(meeting.id, tab: "summary"); app.trashSelected()
        try expect(app.error == nil && !app.meetings.contains(where: { $0.id == meeting.id }), "Native meeting deletion hides active meeting")
        struct Envelope: Decodable { var entries: [TrashEntry] }
        var entries = try JSONDecoder().decode(Envelope.self, from: bridge.request(root: root, command: "trash-list")).entries
        try expect(entries.count == 2 && entries.contains(where: { $0.kind == "meeting" }), "Actual trash DTO covers meeting and note")
        let saved = entries.first(where: { $0.kind == "meeting" })!
        _ = try bridge.request(root: root, command: "trash-change", arguments: ["id":saved.id, "kind":"meeting", "restore":true, "expectedFingerprint":saved.fingerprint, "operationID":UUID().uuidString.lowercased()])
        app.reloadLibrary()
        try expect(app.meetings.contains(where: { $0.id == meeting.id }) && FileManager.default.fileExists(atPath: directory.appendingPathComponent("source.wav").path), "Restoration preserves source")
        struct Cards: Decodable { struct Entry: Decodable { var card: Flashcard; var fingerprint: String }; var entries: [Entry] }
        let cards = try JSONDecoder().decode(Cards.self, from: bridge.request(root: root, command: "cards-library")).entries
        guard let card = cards.first else { throw AppError.message("Card fixture failed") }
        _ = try bridge.request(root: root, command: "card-delete", arguments: ["meetingID":meeting.id,"cardID":card.card.id,"expectedFingerprint":card.fingerprint])
        entries = try JSONDecoder().decode(Envelope.self, from: bridge.request(root: root, command: "trash-list")).entries
        guard let archived = entries.first(where: { $0.kind == "card" }) else { throw AppError.message("Card trash DTO failed") }
        _ = try bridge.request(root: root, command: "card-restore", arguments: ["meetingID":meeting.id,"trashID":archived.id,"expectedFingerprint":archived.fingerprint])
        try expect(try JSONDecoder().decode(Cards.self, from: bridge.request(root: root, command:"cards-library")).entries.count == 1, "Native card restore preserves deck")
        print("PASS: native meeting/note/card trash DTO, delete and restore preserve source, deck and IDs")
        // Keep three believable examples visible for the UI review screenshot.
        let currentCard = try JSONDecoder().decode(Cards.self, from: bridge.request(root: root, command:"cards-library")).entries[0]
        _ = try bridge.request(root: root, command:"card-delete", arguments:["meetingID":meeting.id,"cardID":currentCard.card.id,"expectedFingerprint":currentCard.fingerprint])
        let other = Meeting(title:"Планирование пилота",source:"source.wav",status:"ready")
        try app.write(other,app.meetingDirectory(other.id).appendingPathComponent("meta.json"))
        app.reloadLibrary();app.openMeeting(other.id,tab:"summary");app.trashSelected();app.librarySection="trash";app.notice=nil
        let hosted = NSHostingView(rootView: MainView().environmentObject(app))
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1120,height:760),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.contentView=hosted;window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for:.milliseconds(700));hosted.layoutSubtreeIfNeeded()
        try expect(hosted.fittingSize.width > 0,"Trash workspace lays out")
        if let destination=ProcessInfo.processInfo.environment["POSLE_TRASH_SNAPSHOT"], destination.hasPrefix("/private/tmp/") {
            guard let bitmap=hosted.bitmapImageRepForCachingDisplay(in:hosted.bounds) else {throw AppError.message("Snapshot unavailable")}
            hosted.cacheDisplay(in:hosted.bounds,to:bitmap)
            try bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:destination))
        }
        window.orderOut(nil)
        let settings=NSHostingView(rootView:SummaryContextSettingsView().environmentObject(app));settings.frame=NSRect(x:0,y:0,width:600,height:260);settings.layoutSubtreeIfNeeded()
        try expect(settings.fittingSize.height>0,"Summary context settings lay out")
        print("PASS: actual trash workspace and summary context settings render with native controls")
    }
    private static func expect(_ condition: @autoclosure () throws -> Bool,_ message:String)throws {if try !condition(){throw AppError.message(message)}}
}
#endif
