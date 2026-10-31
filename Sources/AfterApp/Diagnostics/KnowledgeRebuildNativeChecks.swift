#if DEBUG
import AfterLocalization
import AfterPlatform
import AppKit
import Darwin
import Foundation
import AfterCore
import SwiftUI

/// A controlled provider returns a fixed plan; all draft, preview, application,
/// history and undo operations use the real transactional backend.
@MainActor
enum KnowledgeRebuildNativeChecks {
    static func run(store: AppStore) async throws {
        let root = store.root.resolvingSymlinksInPath()
        guard store.isPreview, ProcessInfo.processInfo.arguments.contains("--preview"),
              ["/private/tmp", "/tmp"].contains(root.deletingLastPathComponent().path), root.lastPathComponent.hasPrefix("posle-native-check-") else {
            throw AppError.message("Disposable knowledge rebuild fixture required")
        }
        let originalSettings = store.settings
        defer { store.settings = originalSettings; _ = store.saveSettings() }
        store.settings.mode = "cloud"; store.settings.cloudProvider = "openai"; store.settings.cloudModel = "offline-fixture"
        guard store.saveSettings() else { throw AppError.message("Cannot configure synthetic provider disclosure") }
        guard let originalA = store.notes.save(CapturedNote(id:"rebuild-a", text:"Бюджет пилота 50. Срок запуска — июнь.", title:"Пилот: бюджет и сроки")),
              let originalB = store.notes.save(CapturedNote(id:"rebuild-b", text:"Команда запускает пилот в июне. Ответственный — Анна.", title:"План команды")),
              store.notes.save(CapturedNote(id:"rebuild-excluded", text:"Этот текст нельзя отправлять провайдеру.", title:"Не выбрана")) != nil else {
            throw AppError.message("Cannot create rebuild fixtures")
        }
        func call(_ command: String, _ input: [String:Any] = [:]) async throws -> Data {
            try await KnowledgeRebuildController.liveRequest(root:root, command:command,
                arguments:JSONSerialization.data(withJSONObject:input, options:[.sortedKeys]))
        }
        var generatedIDs = [[String]]()
        let historyGate = RebuildHistoryReadGate()
        defer { historyGate.release() }
        let controller = KnowledgeRebuildController(root:root, generate: { ids, folder, instruction, event in
            generatedIDs.append(ids)
            var input:[String:Any] = ["noteIDs":ids, "instruction":instruction]
            if let folder { input["folderID"] = folder }
            let prepared = try JSONDecoder().decode(KnowledgeRebuildPrepared.self, from: await call("kb-rebuild-prepare", input))
            event("Offline fixture proposal")
            let proposal = KnowledgeRebuildProposal(title:"Пилот: новая структура", summary:"Уточнить исходник, выделить бюджет и собрать общий план.",
                edits:[KnowledgeRebuildEdit(noteID:originalA.id, title:"Уточнённый пилот", text:"Бюджет пилота — 50. Запуск — июнь.")],
                newNotes:[KnowledgeRebuildNewNote(key:"budget",title:"Бюджет",text:"Бюджет пилота — 50.",sourceNoteIDs:[originalA.id]),
                          KnowledgeRebuildNewNote(key:"plan",title:"Общий план",text:"Пилот запускается в июне. Ответственная — Анна.",sourceNoteIDs:[originalA.id,originalB.id])],
                collections:[KnowledgeRebuildCollection(key:"pilot",name:"Пилот",members:[.init(noteID:originalA.id),.init(draftKey:"budget"),.init(draftKey:"plan")]),
                             KnowledgeRebuildCollection(key:"budget-only",name:"Детали бюджета",members:[.init(draftKey:"budget")]),
                             KnowledgeRebuildCollection(key:"optional",name:"Необязательная подборка",members:[.init(noteID:originalB.id)])],
                links:[KnowledgeRebuildLink(from:.init(noteID:originalA.id),to:.init(noteID:originalB.id)),
                       KnowledgeRebuildLink(from:.init(draftKey:"budget"),to:.init(draftKey:"plan"))])
            return try await call("kb-rebuild-preview", ["draftID":prepared.draftID,"expectedDraftRevision":prepared.draftRevision,
                "proposal":JSONSerialization.jsonObject(with:JSONEncoder().encode(proposal))])
        }, request: { root, command, arguments in
            let data = try await KnowledgeRebuildController.liveRequest(root: root, command: command, arguments: arguments)
            if command == "kb-rebuild-history" { await historyGate.pauseFirstRead() }
            return data
        })
        let host = NSHostingView(rootView:KnowledgeRebuildSheet(store:store,controller:controller).background(Ink.paper))
        host.sizingOptions=[]; host.frame=NSRect(x:0,y:0,width:820,height:660)
        let window=NSWindow(contentRect:host.frame,styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.contentView=host;window.makeKeyAndOrderFront(nil)
        defer { controller.cancel();window.orderOut(nil);window.contentView=nil }
        func draw() { host.layoutSubtreeIfNeeded();window.displayIfNeeded() }
        try await wait { draw();return NativeTabNavigation.contains("knowledge.rebuild.generate",in:host) }
        try await wait { historyGate.waiting }
        guard controller.selectedNoteIDs.isEmpty, generatedIDs.isEmpty,
              !enabled("knowledge.rebuild.generate",in:host) else { throw AppError.message("Rebuild must start with zero selected notes and no provider request") }
        let visible=window.convertToScreen(host.convert(host.bounds,to:nil))
        let disclosure=NativeTabNavigation.nodes(in:host).filter{$0.identifier=="knowledge.rebuild.provider-disclosure"}.compactMap(\.frame)
        guard !disclosure.isEmpty,disclosure.allSatisfy({!$0.isEmpty && visible.contains($0)}) else {
            throw AppError.message("Provider disclosure must remain visible beside the explicit generation action")
        }
        let language=UILocalization.shared.language, languageOverride=ProcessInfo.processInfo.environment["POSLE_UI_LANGUAGE"]
        defer {
            if let languageOverride {setenv("POSLE_UI_LANGUAGE",languageOverride,1)} else {unsetenv("POSLE_UI_LANGUAGE")}
            _ = UILocalization.shared.setLanguage(language)
        }
        for locale in [UILanguage.ru,.en] {
            setenv("POSLE_UI_LANGUAGE",locale.rawValue,1);_ = UILocalization.shared.setLanguage(locale)
            try await Task.sleep(for:.milliseconds(80));draw()
            try capture(host,to:root.appendingPathComponent("knowledge-rebuild-selection-"+locale.rawValue+".png"))
        }
        try NativeTabNavigation.press("knowledge.rebuild.select."+originalA.id,in:host)
        try NativeTabNavigation.press("knowledge.rebuild.select."+originalB.id,in:host)
        try replaceEditor("knowledge.rebuild.instruction",in:host,window:window,
            text:"Раздели тексты по темам и собери общий план. Покажи изменения исходника отдельно.")
        try await wait { draw();return enabled("knowledge.rebuild.generate",in:host) }
        guard generatedIDs.isEmpty else {throw AppError.message("Selecting notes or typing triggered a provider request")}
        try NativeTabNavigation.press("knowledge.rebuild.generate",in:host)
        try await wait { draw();return controller.phase == .review && !controller.busy }
        guard generatedIDs == [[originalA.id,originalB.id]], let firstPreview=controller.preview,
              firstPreview.beforeEdits.first?.text == originalA.text,
              store.notes.notes.first(where:{$0.id==originalA.id})?.text == originalA.text,
              !store.notes.notes.contains(where:{$0.title=="Общий план"}) else {
            throw AppError.message("Provider selection leaked or a proposal changed notes before Apply")
        }
        try NativeTabNavigation.press("knowledge.rebuild.remove.new.budget",in:host)
        try await wait {draw();return controller.proposal?.newNotes.count==1}
        guard controller.reviewChanged,
              controller.proposal?.collections.contains(where:{$0.key=="budget-only"})==false,
              controller.proposal?.collections.flatMap(\.members).contains(where:{$0.draftKey=="budget"})==false,
              controller.proposal?.links.contains(where:{$0.from.draftKey=="budget" || $0.to.draftKey=="budget"})==false else {
            throw AppError.message("Removing a proposed note left dangling links, collection members, or an empty group")
        }
        controller.apply()
        guard controller.activity==nil,controller.receipt==nil else {throw AppError.message("Structural review edits bypassed revalidation")}
        try NativeTabNavigation.press("knowledge.rebuild.remove.collection.optional",in:host)
        guard controller.proposal?.collections.count==1 else {throw AppError.message("Rejected group remained in the proposal")}
        // Original-note rejection removes only its edit; source references
        // remain valid because the original itself is never deleted.
        let structural=KnowledgeRebuildController(root:root) { _,_,_,_ in throw AppError.message("Unused test provider") }
        structural.proposal=firstPreview.proposal;structural.removeEdit(originalA.id);structural.removeLink(0)
        guard structural.proposal?.edits.isEmpty==true,structural.proposal?.links.count==1,
              structural.proposal?.collections.first?.members.contains(.init(noteID:originalA.id))==true else {
            throw AppError.message("Rejecting an original edit or link removed unrelated proposal content")
        }
        try editField(window,placeholder:L("Название подборки"),text:"Пилот — проверено мной")
        try replaceEditor("knowledge.rebuild.new.text.plan",in:host,window:window,text:"Проверенный план: июнь, Анна; бюджет — 50.")
        try await wait {draw();return controller.reviewChanged && NativeTabNavigation.contains("knowledge.rebuild.validate",in:host)}
        controller.apply()
        guard controller.activity == nil, controller.receipt == nil else {throw AppError.message("Dirty review bypassed explicit revalidation")}
        try NativeTabNavigation.press("knowledge.rebuild.validate",in:host)
        try await wait {draw();return !controller.busy && !controller.reviewChanged}
        guard controller.preview?.draftRevision == firstPreview.draftRevision + 1,
              controller.proposal?.collections.first?.name == "Пилот — проверено мной",
              controller.proposal?.newNotes.first(where:{$0.key=="plan"})?.text == "Проверенный план: июнь, Анна; бюджет — 50.",
              controller.receipt == nil, store.notes.notes.first(where:{$0.id==originalA.id})?.text == originalA.text else {
            throw AppError.message("Revalidation lost edits or applied them automatically")
        }
        let cancellationPreview=try JSONEncoder().encode(controller.preview)
        try capture(host,to:root.appendingPathComponent("knowledge-rebuild-review-detail.png"))
        // Text editing deliberately scrolls to that field. Also capture the
        // top of the final review, including the original before/after pair.
        window.makeFirstResponder(nil)
        if let document=views(host,as:NSScrollView.self).first(where:{$0.frame.width>600 && $0.frame.height>200})?.documentView {
            document.scroll(NSPoint(x:0,y:0))
        }
        for locale in [UILanguage.ru,.en] {
            setenv("POSLE_UI_LANGUAGE",locale.rawValue,1);_ = UILocalization.shared.setLanguage(locale)
            try await Task.sleep(for:.milliseconds(80));draw()
            try capture(host,to:root.appendingPathComponent("knowledge-rebuild-review-"+locale.rawValue+".png"))
        }
        try NativeTabNavigation.press("knowledge.rebuild.apply",in:host)
        try await wait {draw();return controller.phase == .finished && !controller.busy && controller.receipt != nil}
        // The initial real history snapshot predates Apply and is still
        // blocked. Apply's refresh must be replayed, not silently dropped.
        historyGate.release()
        try await wait { !controller.historyLoading }
        guard historyGate.reads >= 2 else { throw AppError.message("Apply lost its history refresh behind an older in-flight read") }
        guard let applied=controller.receipt, let operation=controller.history.first(where:{$0.operationID==applied.operationID}),
              applied.createdNotes.count==1, applied.editedNoteIDs == [originalA.id], applied.collectionIDs.count==1,
              store.notes.notes.first(where:{$0.id==originalA.id})?.text == "Бюджет пилота — 50. Запуск — июнь.",
              store.notes.notes.first(where:{$0.id==originalB.id})?.text == originalB.text,
              store.notes.notes.contains(where:{$0.id=="rebuild-excluded"}) else {throw AppError.message("Approved rebuild did not apply exact changes atomically")}
        try NativeTabNavigation.press("knowledge.rebuild.tab.history",in:host)
        try await wait {draw();return enabled("knowledge.rebuild.undo."+operation.operationID,in:host)}
        try capture(host,to:root.appendingPathComponent("knowledge-rebuild-history.png"))
        try NativeTabNavigation.press("knowledge.rebuild.undo."+operation.operationID,in:host)
        try await wait {draw();return !controller.busy && controller.receipt?.undone==true}
        guard store.notes.notes.first(where:{$0.id==originalA.id})?.text == originalA.text,
              store.notes.notes.first(where:{$0.id==originalB.id})?.text == originalB.text,
              !store.notes.notes.contains(where:{note in applied.createdNotes.contains{$0.noteID==note.id}}) else {
            throw AppError.message("Undo did not restore originals and remove only its newly created notes")
        }
        // A stale review must preserve user edits, and a failed mutation must
        // not overwrite a concurrent user change or create half the plan.
        controller.startOver();controller.selectedNoteIDs=[originalA.id,originalB.id]
        controller.generate(notes:store.notes.notes,folderID:nil,provider:"offline fixture")
        try await wait {controller.phase == .review && !controller.busy}
        guard var changed=store.notes.notes.first(where:{$0.id==originalA.id}) else {throw AppError.message("Original disappeared")}
        changed.text="Чужая правка после подготовки предложения"
        guard store.notes.save(changed) != nil else {throw AppError.message("Cannot create concurrent edit")}
        controller.proposal?.collections[0].name="Моя несохранённая правка"
        controller.validateEdits()
        try await wait {!controller.busy}
        guard controller.error != nil, controller.reviewChanged,
              controller.proposal?.collections.first?.name=="Моя несохранённая правка",
              store.notes.notes.first(where:{$0.id==originalA.id})?.text==changed.text else {
            throw AppError.message("Stale revalidation lost dirty fields or overwrote a concurrent edit")
        }
        controller.startOver();controller.selectedNoteIDs=[originalA.id,originalB.id]
        controller.generate(notes:store.notes.notes,folderID:nil,provider:"offline fixture")
        try await wait {controller.phase == .review && !controller.busy}
        controller.apply();try await wait {!controller.busy && controller.phase == .finished}
        guard let secondReceipt=controller.receipt,
              let beforeConflict=controller.history.first(where:{$0.operationID==secondReceipt.operationID}),beforeConflict.canUndo,
              var editedAfterApply=store.notes.notes.first(where:{$0.id==originalA.id}) else {throw AppError.message("Second application failed")}
        editedAfterApply.text="Не затирать: правка после применения"
        guard store.notes.save(editedAfterApply) != nil else {throw AppError.message("Cannot create undo conflict")}
        controller.undo(beforeConflict)
        try await wait {!controller.busy}
        guard controller.error != nil, store.notes.notes.first(where:{$0.id==originalA.id})?.text==editedAfterApply.text,
              controller.history.first(where:{$0.operationID==secondReceipt.operationID})?.canUndo==false else {
            throw AppError.message("Undo overwrote a newer edit or remained advertised as safe")
        }
        // An uncancellable late provider response is ignored after dismissal.
        var continuation:CheckedContinuation<Data,Never>?
        let cancelled=KnowledgeRebuildController(root:root) { _,_,_,_ in
            await withCheckedContinuation { continuation=$0 }
        }
        cancelled.selectedNoteIDs=[originalA.id];cancelled.instruction="Подготовь предложение"
        cancelled.generate(notes:store.notes.notes,folderID:nil,provider:"offline fixture")
        try await wait {continuation != nil}
        cancelled.cancel();continuation?.resume(returning:cancellationPreview)
        try await Task.sleep(for:.milliseconds(80))
        guard cancelled.preview==nil,cancelled.phase == .select,cancelled.receipt==nil else {throw AppError.message("Cancelled generation resurrected a plan or applied changes")}
        print("PASS: rebuild requires explicit selected-note consent, shows review, preserves editable text/names, and never auto-applies")
        print("PASS: rejecting proposed parts removes dependent references and requires a fresh server preview before Apply")
        print("PASS: rebuild applies and safely undoes real split/merge provenance; stale reviews and conflicting undo preserve user changes")
        print("PASS: an initial delayed history snapshot cannot swallow Apply's refresh or hide its operation")
        print("PASS: cancelled late provider results are ignored; no real provider or credentials used")
    }
    private static func enabled(_ id:String,in root:NSView)->Bool {NativeTabNavigation.nodes(in:root).contains{$0.identifier==id && $0.enabled}}
    private static func views<T:NSView>(_ root:NSView,as type:T.Type)->[T] {(root as? T).map{[$0]} ?? root.subviews.flatMap{views($0,as:type)}}
    private static func editField(_ window:NSWindow,placeholder:String,text:String)throws {
        guard let root=window.contentView,let field=views(root,as:NSTextField.self).first(where:{$0.placeholderString==placeholder}) else {throw AppError.message("Rebuild name field missing")}
        field.scrollToVisible(field.bounds);window.makeFirstResponder(field)
        guard let editor=field.currentEditor() as? NSTextView else {throw AppError.message("Rebuild name editor unavailable")}
        editor.selectAll(nil);editor.insertText(text,replacementRange:editor.selectedRange())
    }
    private static func replaceEditor(_ id:String,in root:NSView,window:NSWindow,text:String)throws {
        root.layoutSubtreeIfNeeded()
        guard let target=NativeTabNavigation.nodes(in:root).first(where:{$0.identifier==id}),let targetFrame=target.frame else {throw AppError.message("Rebuild text editor missing: "+id)}
        let candidates=views(root,as:NSTextView.self).filter{$0.isEditable && !$0.isFieldEditor}
        let ranked=candidates.map { view -> (NSTextView,CGFloat) in
            let frame=window.convertToScreen(view.convert(view.bounds,to:nil)),overlap=frame.intersection(targetFrame)
            return (view,overlap.isNull ? 0:overlap.width*overlap.height)
        }.sorted{$0.1>$1.1}
        guard let (editor,score)=ranked.first,score>0 else {throw AppError.message("Rebuild native text view unavailable: "+id)}
        editor.scrollToVisible(editor.bounds);window.makeFirstResponder(editor)
        editor.selectAll(nil);editor.insertText(text,replacementRange:editor.selectedRange())
    }
    private static func capture(_ view:NSView,to url:URL)throws {
        view.layoutSubtreeIfNeeded();view.displayIfNeeded()
        guard let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) else {throw AppError.message("Rebuild screenshot failed")}
        view.cacheDisplay(in:view.bounds,to:bitmap)
        guard let cg=bitmap.cgImage,let opaque=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:bitmap.pixelsWide,pixelsHigh:bitmap.pixelsHigh,
            bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0),
            let context=NSGraphicsContext(bitmapImageRep:opaque) else {throw AppError.message("Rebuild opaque screenshot failed")}
        context.cgContext.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.cgContext.fill(CGRect(x:0,y:0,width:bitmap.pixelsWide,height:bitmap.pixelsHigh))
        context.cgContext.draw(cg,in:CGRect(x:0,y:0,width:bitmap.pixelsWide,height:bitmap.pixelsHigh))
        guard let png=opaque.representation(using:.png,properties:[:]) else {throw AppError.message("Rebuild screenshot encoding failed")}
        try png.write(to:url)
    }
    private static func wait(line:UInt=#line,_ predicate:()->Bool)async throws {
        for _ in 0..<1500 {if predicate(){return};try await Task.sleep(for:.milliseconds(10))}
        throw AppError.message("Knowledge rebuild UI timed out at line \(line)")
    }
}
@MainActor
private final class RebuildHistoryReadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var reads = 0
    var waiting: Bool { continuation != nil }
    func pauseFirstRead() async {
        reads += 1
        if reads == 1 { await withCheckedContinuation { continuation = $0 } }
    }
    func release() {
        let pending = continuation; continuation = nil; pending?.resume()
    }
}

#endif
