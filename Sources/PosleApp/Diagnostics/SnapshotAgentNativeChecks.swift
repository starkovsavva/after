#if DEBUG
import AppKit
import Foundation
import PosleCore
import SwiftUI

@MainActor enum SnapshotAgentNativeChecks {
    static func run() async throws {
        let env = ProcessInfo.processInfo.environment
        guard ProcessInfo.processInfo.arguments.contains("--preview"), let path = env["POSLE_DATA_DIR"],
              let engine = env["POSLE_RUST_ENGINE"], let library = env["POSLE_RUST_LIBRARY"],
              FileManager.default.fileExists(atPath: engine), FileManager.default.fileExists(atPath: library) else { throw AppError.message("Disposable preview and current core/engine required") }
        let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard ["/private/tmp", "/tmp"].contains(root.deletingLastPathComponent().path), root.lastPathComponent.hasPrefix("posle-native-check-") else { throw AppError.message("Disposable root required") }
        let app = AppStore(preview: true); app.settings.features.tasks = true; app.settings.features.knowledgeBase = true
        guard app.saveSettings(), let note = app.notes.save(CapturedNote(id: "share-note", text: "NEPTUNE launch Friday", title: "Launch plan")),
              app.notes.save(CapturedNote(id: "private-note", text: "FORBIDDEN private material", title: "Private")) != nil else { throw AppError.message("Could not create share fixture") }
        let bridge = try RustBridge.shared.get()
        let taskData = try bridge.request(root: root, command: "task-create", arguments: ["title": "Synthetic task", "text": "Check the launch", "operationID": UUID().uuidString])
        let task = try JSONDecoder().decode(TaskWorkspace.self, from: taskData)
        let process = Process(); process.executableURL = URL(fileURLWithPath: engine); process.arguments = ["mcp-share", "--root", root.path]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let input = Pipe(), output = Pipe(); process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run(); defer { try? input.fileHandleForWriting.close(); if process.isRunning { process.terminate() } }
        var serial = 0
        func rpc(_ method: String, _ params: [String: Any], input: Pipe, output: Pipe) async throws -> [String: Any] {
            serial += 1
            var request = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": serial, "method": method, "params": params]); request.append(10)
            try input.fileHandleForWriting.write(contentsOf: request)
            let handle = output.fileHandleForReading
            let response = try await Task.detached { () throws -> Data in
                var data = Data()
                while data.count < 2_000_000 {
                    guard let one = try handle.read(upToCount: 1), !one.isEmpty else { throw AppError.message("MCP closed before response") }
                    if one[0] == 10 { return data }; data.append(one)
                }
                throw AppError.message("MCP response too large")
            }.value
            guard let result = (try JSONSerialization.jsonObject(with: response) as? [String: Any])?["result"] as? [String: Any] else { throw AppError.message("MCP result missing") }
            return result
        }
        func call(_ method: String, _ params: [String: Any]) async throws -> [String: Any] { try await rpc(method, params, input: input, output: output) }
        _ = try await call("initialize", ["protocolVersion": "2024-11-05", "capabilities": [:], "clientInfo": ["name": "Native fixture", "version": "1"]])
        let status = try await call("tools/call", ["name": "after_share_status", "arguments": [:]])
        guard (status["structuredContent"] as? [String: Any])?["approved"] as? Bool == false else { throw AppError.message("Unexpected approval") }
        let connectionsData = try bridge.request(root: root, command: "agent-share-connections")
        struct Connections: Decodable { var connections: [AgentShareConnection] }
        guard let connection = try JSONDecoder().decode(Connections.self, from: connectionsData).connections.first else { throw AppError.message("Connection not visible") }
        let host = NSHostingView(rootView: TaskSnapshotShareSheet(root: root, notes: app.notes, taskID: task.id).environmentObject(app).background(Ink.paper)); host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: 740, height: 760)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        let mode = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"); let previous = NSApp.accessibilityAttributeValue(mode)
        NSApp.accessibilitySetValue(true, forAttribute: mode); window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; NSApp.accessibilitySetValue(previous, forAttribute: mode) }
        try await click("snapshot.enabled", host)
        try await click("snapshot.connection." + connection.id, host)
        try await click("snapshot.note." + note.id, host)
        try await click("snapshot.preview", host)
        try await wait { host.layoutSubtreeIfNeeded(); return find("snapshot.review-code", in: host) != nil }
        try await click("snapshot.approve", host)
        try await wait { host.layoutSubtreeIfNeeded(); return find("snapshot.approved", in: host) != nil }
        guard find("snapshot.preview", in: host) == nil, find("snapshot.approved-summary", in: host) != nil,
              find("snapshot.new-code-instructions", in: host) != nil else { throw AppError.message("Approval did not show a distinct completed handoff with expiry and renewal instructions") }
        try snapshot(host, at: root.appendingPathComponent("agent-approved.png"))
        let found = try await call("tools/call", ["name": "after_share_search", "arguments": ["query": "NEPTUNE"]])
        guard let source = ((found["structuredContent"] as? [String: Any])?["sources"] as? [[String: Any]])?.first,
              let sourceID = source["id"] as? String, let fingerprint = source["fingerprint"] as? String else { throw AppError.message("Approved source not found") }
        _ = try await call("tools/call", ["name": "after_share_read", "arguments": ["sourceID": sourceID, "fingerprint": fingerprint]])
        let beforeReport = try JSONDecoder().decode(AgentShareHistory.self, from: bridge.request(root: root, command: "agent-share-history", arguments: ["taskID": task.id]))
        guard let savedShare = beforeReport.shares.first else { throw AppError.message("Approved share missing") }
        try await click("snapshot.new", host)
        try await click("snapshot.note." + note.id, host)
        guard find("snapshot.connection." + connection.id, in: host) == nil,
              NativeTabNavigation.nodes(in: host).contains(where: { $0.identifier == "snapshot.preview" && !$0.enabled }) else { throw AppError.message("An approved connection enabled a second preview") }
        let staleController = AgentShareController(root: root)
        await staleController.load(); await staleController.prepare(taskID: task.id, notes: [note])
        guard !(await staleController.approve(connectionID: connection.id)), staleController.error != nil else { throw AppError.message("Controller accepted an already approved connection") }
        // A second, independent client can own a different copy of this task.
        // Its report arrives first, so history cannot associate reports by order.
        let secondProcess = Process(); secondProcess.executableURL = URL(fileURLWithPath: engine); secondProcess.arguments = ["mcp-share", "--root", root.path]
        secondProcess.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let secondInput = Pipe(), secondOutput = Pipe(); secondProcess.standardInput = secondInput; secondProcess.standardOutput = secondOutput; secondProcess.standardError = FileHandle.nullDevice
        try secondProcess.run(); defer { try? secondInput.fileHandleForWriting.close(); if secondProcess.isRunning { secondProcess.terminate() } }
        func secondCall(_ method: String, _ params: [String: Any]) async throws -> [String: Any] { try await rpc(method, params, input: secondInput, output: secondOutput) }
        _ = try await secondCall("initialize", ["protocolVersion": "2024-11-05", "capabilities": [:], "clientInfo": ["name": "Independent native fixture", "version": "1"]])
        _ = try await secondCall("tools/call", ["name": "after_share_status", "arguments": [:]])
        let secondPending = try JSONDecoder().decode(Connections.self, from: bridge.request(root: root, command: "agent-share-connections"))
        guard let secondConnection = secondPending.connections.first else { throw AppError.message("Independent connection missing") }
        try await click("snapshot.connection." + secondConnection.id, host)
        try await click("snapshot.preview", host)
        try await click("snapshot.approve", host)
        try await wait { host.layoutSubtreeIfNeeded(); return find("snapshot.approved", in: host) != nil }
        let independentHistory = try JSONDecoder().decode(AgentShareHistory.self, from: bridge.request(root: root, command: "agent-share-history", arguments: ["taskID": task.id]))
        guard let secondShare = independentHistory.shares.first(where: { $0.id != savedShare.id }),
              independentHistory.shares.count == 2, independentHistory.shares.allSatisfy({ !$0.revoked }),
              savedShare.expiresAt - savedShare.createdAt == 86400 else { throw AppError.message("Independent approvals did not preserve separate 24-hour grants") }
        let secondReportResult = try await secondCall("tools/call", ["name": "after_share_report", "arguments": ["snapshotID": secondShare.id, "operationID": UUID().uuidString, "text": "The second client reports first.", "completed": true]])
        guard let secondReportID = (secondReportResult["structuredContent"] as? [String: Any])?["id"] as? String else { throw AppError.message("Independent report missing") }
        let historyHost = NSHostingView(rootView: ScrollView { TaskHistoryView(task: task).environmentObject(app).padding(24) }.background(Ink.paper)); historyHost.sizingOptions = []; historyHost.frame = host.frame; window.contentView = historyHost
        try await wait { historyHost.layoutSubtreeIfNeeded(); return find("snapshot.history.sources." + savedShare.id, in: historyHost) != nil }
        let reportResult = try await call("tools/call", ["name": "after_share_report", "arguments": ["snapshotID": savedShare.id, "operationID": UUID().uuidString, "text": "Checked the launch snapshot.", "completed": true, "evidence": [["sourceID": sourceID, "fingerprint": fingerprint]], "artifacts": [["title": "Launch checklist", "text": "Verify the deployment."]]]])
        guard let reportID = (reportResult["structuredContent"] as? [String: Any])?["id"] as? String else { throw AppError.message("Report missing") }
        try await wait { historyHost.layoutSubtreeIfNeeded(); return find("snapshot.history.report." + reportID, in: historyHost) != nil }
        guard find("snapshot.history.report-date." + reportID, in: historyHost) != nil,
              find("snapshot.history.report-snapshot." + reportID + "." + savedShare.id, in: historyHost) != nil,
              find("snapshot.history.report-snapshot." + secondReportID + "." + secondShare.id, in: historyHost) != nil else { throw AppError.message("Out-of-order reports lost their dates or exact snapshot links") }
        try snapshot(historyHost, at: root.appendingPathComponent("agent-history.png"))
        try await click("snapshot.history.report-snapshot." + secondReportID + "." + secondShare.id, historyHost)
        try await wait { window.sheets.first?.contentView.map { find("snapshot.saved." + secondShare.id, in: $0) != nil } == true }
        guard let snapshotContent = window.sheets.first?.contentView else { throw AppError.message("Report snapshot sheet missing") }
        try await click("snapshot.sources.close", snapshotContent)
        try await wait { window.sheets.isEmpty }
        print("snapshot check: report is visible")
        try await click("snapshot.history.evidence." + reportID + "." + sourceID, historyHost)
        try await wait { !window.sheets.isEmpty }
        print("snapshot check: evidence sheet is open")
        guard let evidenceSheet = window.sheets.first else { throw AppError.message("Evidence sheet missing") }
        try await wait { evidenceSheet.contentView.map { find("snapshot.source." + sourceID, in: $0) != nil } == true }
        print("snapshot check: saved source is visible")
        guard let evidenceContent = evidenceSheet.contentView else { throw AppError.message("Evidence content missing") }
        try await click("snapshot.sources.close", evidenceContent)
        try await wait { window.sheets.isEmpty }
        try await click("snapshot.history.artifact." + reportID + ".0", historyHost)
        try await wait { !window.sheets.isEmpty }
        print("snapshot check: artifact sheet is open")
        guard let sheet = window.sheets.first else { throw AppError.message("Artifact sheet missing") }
        try await wait { sheet.contentView.map { find("tasks.artifact.contents." + reportID + "0", in: $0) != nil } == true }
        print("snapshot check: artifact text is visible")
        guard let artifactContent = sheet.contentView else { throw AppError.message("Artifact content missing") }
        try await click("tasks.artifact.close", artifactContent)
        try await wait { window.sheets.isEmpty }
        try await click("snapshot.history.revoke." + savedShare.id, historyHost)
        try await wait { let data = try? bridge.request(root: root, command: "agent-share-history", arguments: ["taskID": task.id]); return data.flatMap { try? JSONDecoder().decode(AgentShareHistory.self, from: $0) }?.shares.first(where: { $0.id == savedShare.id })?.revoked == true }
        let denied = try await call("tools/call", ["name": "after_share_search", "arguments": ["query": "NEPTUNE"]])
        guard denied["isError"] as? Bool == true else { throw AppError.message("Revoked connection could still read") }
        let lateReport = try await call("tools/call", ["name": "after_share_report", "arguments": ["snapshotID": savedShare.id, "operationID": UUID().uuidString, "text": "Must be rejected"]])
        guard lateReport["isError"] as? Bool == true else { throw AppError.message("Revoked snapshot accepted a new report") }
        // Renew without restarting the MCP client, then verify that the native
        // master revoke remains reachable even after Tasks is disabled.
        let renewed = try await call("tools/call", ["name": "after_share_request_snapshot", "arguments": [:]])
        guard let code = (renewed["structuredContent"] as? [String: Any])?["connectionCode"] as? String else { throw AppError.message("Renewed code missing") }
        let pending = try JSONDecoder().decode(Connections.self, from: bridge.request(root: root, command: "agent-share-connections"))
        guard let next = pending.connections.first(where: { $0.code == code }) else { throw AppError.message("Renewal not pending") }
        let preview = try JSONDecoder().decode(AgentSharePreview.self, from: bridge.request(root: root, command: "agent-share-preview", arguments: ["taskID": task.id, "sources": [["noteID": note.id, "revision": note.revision]]]))
        _ = try bridge.request(root: root, command: "agent-share-approve", arguments: ["draftID": preview.id, "digest": preview.digest, "sessionID": next.id])
        window.contentView = host
        try await wait { host.layoutSubtreeIfNeeded(); return find("snapshot.approved", in: host) != nil }
        try await click("snapshot.enabled", host)
        try await wait {
            host.layoutSubtreeIfNeeded()
            let revokedIDs = Set(NativeTabNavigation.nodes(in: host).filter { $0.identifier?.hasPrefix("snapshot.status.") == true && $0.value == L("Доступ отозван") }.compactMap(\.identifier))
            return find("snapshot.approved", in: host) == nil && find("snapshot.notice", in: host) != nil && revokedIDs.count == 3
        }
        // Restore a fresh explicit grant to verify the master switch also stays
        // reachable from Settings after the unrelated Tasks feature is disabled.
        let controller = AgentShareController(root: root)
        await controller.load(); await controller.setEnabled(true)
        _ = try await call("tools/call", ["name": "after_share_request_snapshot", "arguments": [:]])
        await controller.load(); await controller.prepare(taskID: task.id, notes: [note])
        guard let finalConnection = controller.connections.first, await controller.approve(connectionID: finalConnection.id) else { throw AppError.message("Could not restore fresh access for settings revocation check") }
        app.settings.features.tasks = false
        guard app.saveSettings() else { throw AppError.message("Could not disable Tasks") }
        let stillApproved = try await call("tools/call", ["name": "after_share_status", "arguments": [:]])
        guard (stillApproved["structuredContent"] as? [String: Any])?["approved"] as? Bool == true else { throw AppError.message("Legacy setting unexpectedly owned snapshot access") }
        let settingsHost = NSHostingView(rootView: SettingsView(section: "integrations").environmentObject(app))
        settingsHost.sizingOptions = []; settingsHost.frame = NSRect(x: 0, y: 0, width: 1000, height: 780); window.contentView = settingsHost
        try await wait { settingsHost.layoutSubtreeIfNeeded(); return find("snapshot.settings.enabled", in: settingsHost) != nil }
        try await click("snapshot.settings.enabled", settingsHost)
        try await wait {
            guard let data = try? bridge.request(root: root, command: "agent-share-settings"), let access = try? JSONDecoder().decode(AgentShareAccess.self, from: data) else { return false }
            return !access.enabled
        }
        let allRevoked = try JSONDecoder().decode(AgentShareHistory.self, from: bridge.request(root: root, command: "agent-share-history", arguments: ["taskID": task.id]))
        guard allRevoked.shares.count == 4, allRevoked.shares.allSatisfy(\.revoked), allRevoked.reports.count == 2 else { throw AppError.message("Master revoke did not preserve history and revoke every share") }
        let sourcesDenied = try await call("tools/call", ["name": "after_share_sources", "arguments": [:]])
        guard sourcesDenied["isError"] as? Bool == true else { throw AppError.message("Master-disabled client enumerated sources") }
        try await selectionChecks(app: app, taskID: task.id, window: window)
        print("PASS: snapshot preview, explicit approval, real MCP search/read/report, history artifact and UI revocation")
        print("PASS: renewed connection requires new approval; Settings can revoke all shares with Tasks disabled")
    }
    private static func selectionChecks(app: AppStore, taskID: String, window: NSWindow) async throws {
        let notes = NotesStore(root: app.root)
        notes.workspace = NotesWorkspace(notes: [], templates: [], contexts: [])
        let host = NSHostingView(rootView: TaskSnapshotShareSheet(root: app.root, notes: notes, taskID: taskID).environmentObject(app).background(Ink.paper))
        host.sizingOptions = []; host.frame = NSRect(x: 0, y: 0, width: 740, height: 760); window.contentView = host
        try await wait { host.layoutSubtreeIfNeeded(); return find("snapshot.empty-notes", in: host) != nil }
        notes.workspace = NotesWorkspace(notes: (0..<51).map { CapturedNote(id: "limit-\($0)", text: "Selection fixture \($0)") }, templates: [], contexts: [])
        for index in 0..<50 { try await click("snapshot.note.limit-\(index)", host) }
        try await wait { host.layoutSubtreeIfNeeded(); return find("snapshot.selection-limit", in: host) != nil }
        guard NativeTabNavigation.nodes(in: host).contains(where: { $0.identifier == "snapshot.note.limit-50" && !$0.enabled }) else { throw AppError.message("The 51st note stayed enabled at the selection limit") }
        try await click("snapshot.note.limit-0", host)
        try await wait { host.layoutSubtreeIfNeeded(); return NativeTabNavigation.nodes(in: host).contains { $0.identifier == "snapshot.note.limit-50" && $0.enabled } }
        try await click("snapshot.note.limit-50", host)
        func fields(_ view: NSView) -> [NSTextField] { (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields) }
        guard let field = fields(host).first(where: { $0.placeholderString == L("Поиск") }) else { throw AppError.message("Snapshot search field unavailable") }
        window.makeFirstResponder(field)
        guard let editor = field.currentEditor() as? NSTextView else { throw AppError.message("Snapshot search editor unavailable") }
        editor.selectAll(nil); editor.insertText("unmatched-query-fixture", replacementRange: editor.selectedRange())
        try await wait { host.layoutSubtreeIfNeeded(); return find("snapshot.empty-notes", in: host) != nil && find("snapshot.clear-search", in: host) != nil }
        try await click("snapshot.clear-search", host)
        try await wait { host.layoutSubtreeIfNeeded(); return find("snapshot.empty-notes", in: host) == nil && find("snapshot.note.limit-50", in: host) != nil }
        print("PASS: empty library/search guidance and a reversible 50-note selection limit use actual native controls")
    }
    private static func snapshot(_ view: NSView, at url: URL) throws {
        view.layoutSubtreeIfNeeded(); view.window?.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw AppError.message("Snapshot UI image unavailable") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw AppError.message("Snapshot UI PNG unavailable") }
        try data.write(to: url)
    }
    private static func wait(line: UInt = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<1500 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw AppError.message("Snapshot UI timed out at line \(line)")
    }
    private static func find(_ id: String, in root: NSView) -> NSObject? {
        var seen = Set<ObjectIdentifier>()
        func attr(_ obj: NSObject, _ name: String) -> Any? { let sel = NSSelectorFromString(name); return obj.responds(to: sel) ? obj.perform(sel)?.takeUnretainedValue() : nil }
        func visit(_ obj: NSObject) -> NSObject? {
            guard seen.insert(ObjectIdentifier(obj)).inserted else { return nil }
            if attr(obj, "accessibilityIdentifier") as? String == id { return obj }
            let children = (attr(obj, "accessibilityChildren") as? [NSObject] ?? []) + ((obj as? NSView)?.subviews.map { $0 as NSObject } ?? [])
            for child in children { if let found = visit(child) { return found } }; return nil
        }
        return visit(root)
    }
    private static func click(_ id: String, _ root: NSView) async throws {
        for _ in 0..<1500 {
            root.layoutSubtreeIfNeeded()
            if let obj = find(id, in: root) {
                if let button = obj as? NSButton, button.isEnabled { button.performClick(nil); return }
                let sel = NSSelectorFromString("accessibilityPerformPress")
                if obj.responds(to: sel), let method = obj.method(for: sel) { typealias Press = @convention(c) (AnyObject, Selector) -> Bool; if unsafeBitCast(method, to: Press.self)(obj, sel) { return } }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AppError.message("Snapshot control unavailable: \(id)")
    }
}
#endif
