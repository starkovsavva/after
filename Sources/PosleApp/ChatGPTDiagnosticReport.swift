import AppKit
import Foundation
import PosleCore

/// Only typed transport metadata crosses this boundary. Unknown fields are
/// discarded; unknown enum values or missing/oversized counters reject copying.
struct ChatGPTDiagnostics: Decodable, Equatable, Sendable {
    let httpStatus: UInt16
    let contentType: String
    let wire: String
    let responseBytes: UInt64
    let events: UInt64
    let outputTextDelta: UInt64
    let outputTextDone: UInt64
    let contentPartDone: UInt64
    let outputItemDone: UInt64
    let completed: UInt64
    let otherEvents: UInt64
    let terminalStatus: String
    let terminalOutput: String
    let terminalOutputItems: UInt64
    let terminalTextParts: UInt64
    let terminalRefusalParts: UInt64
    let terminalOtherParts: UInt64
    let accumulatedTextBytes: UInt64

    private enum CodingKeys: String, CodingKey {
        case httpStatus = "http_status", contentType = "content_type", wire
        case responseBytes = "response_bytes", events
        case outputTextDelta = "output_text_delta", outputTextDone = "output_text_done"
        case contentPartDone = "content_part_done", outputItemDone = "output_item_done"
        case completed, otherEvents = "other_events", terminalStatus = "terminal_status"
        case terminalOutput = "terminal_output", terminalOutputItems = "terminal_output_items"
        case terminalTextParts = "terminal_text_parts", terminalRefusalParts = "terminal_refusal_parts"
        case terminalOtherParts = "terminal_other_parts", accumulatedTextBytes = "accumulated_text_bytes"
    }
    init(from decoder: Decoder) throws {
        let value = try decoder.container(keyedBy: CodingKeys.self)
        httpStatus = try value.decode(UInt16.self, forKey: .httpStatus)
        contentType = try value.decode(String.self, forKey: .contentType)
        wire = try value.decode(String.self, forKey: .wire)
        terminalStatus = try value.decode(String.self, forKey: .terminalStatus)
        terminalOutput = try value.decode(String.self, forKey: .terminalOutput)
        responseBytes = try value.decode(UInt64.self, forKey: .responseBytes)
        events = try value.decode(UInt64.self, forKey: .events)
        outputTextDelta = try value.decode(UInt64.self, forKey: .outputTextDelta)
        outputTextDone = try value.decode(UInt64.self, forKey: .outputTextDone)
        contentPartDone = try value.decode(UInt64.self, forKey: .contentPartDone)
        outputItemDone = try value.decode(UInt64.self, forKey: .outputItemDone)
        completed = try value.decode(UInt64.self, forKey: .completed)
        otherEvents = try value.decode(UInt64.self, forKey: .otherEvents)
        terminalOutputItems = try value.decode(UInt64.self, forKey: .terminalOutputItems)
        terminalTextParts = try value.decode(UInt64.self, forKey: .terminalTextParts)
        terminalRefusalParts = try value.decode(UInt64.self, forKey: .terminalRefusalParts)
        terminalOtherParts = try value.decode(UInt64.self, forKey: .terminalOtherParts)
        accumulatedTextBytes = try value.decode(UInt64.self, forKey: .accumulatedTextBytes)
        let counts = [events, outputTextDelta, outputTextDone, contentPartDone,
                      outputItemDone, completed, otherEvents, terminalOutputItems, terminalTextParts,
                      terminalRefusalParts, terminalOtherParts, accumulatedTextBytes]
        guard (100...599).contains(httpStatus),
              ["text/event-stream", "application/json", "application/problem+json", "text/html", "text/plain", "application/octet-stream", "missing", "other"].contains(contentType),
              ["sse", "json", "unknown"].contains(wire),
              ["completed", "incomplete", "failed", "cancelled", "queued", "in_progress", "missing", "other"].contains(terminalStatus),
              ["missing", "array", "invalid"].contains(terminalOutput),
              // Rust reads at most one 16 KiB chunk beyond its stream limit
              // before reporting an oversized response. Preserve that diagnosis.
              responseBytes <= 8 * 1024 * 1024 + 16 * 1024,
              counts.allSatisfy({ $0 <= 8 * 1024 * 1024 }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid ChatGPT diagnostic metadata"))
        }
    }

    fileprivate var fields: [(String, String)] {
        [("http_status", String(httpStatus)), ("content_type", contentType), ("wire", wire),
         ("response_bytes", String(responseBytes)), ("events", String(events)),
         ("output_text_delta", String(outputTextDelta)), ("output_text_done", String(outputTextDone)),
         ("content_part_done", String(contentPartDone)), ("output_item_done", String(outputItemDone)),
         ("completed", String(completed)), ("other_events", String(otherEvents)),
         ("terminal_status", terminalStatus), ("terminal_output", terminalOutput),
         ("terminal_output_items", String(terminalOutputItems)), ("terminal_text_parts", String(terminalTextParts)),
         ("terminal_refusal_parts", String(terminalRefusalParts)), ("terminal_other_parts", String(terminalOtherParts)),
         ("accumulated_text_bytes", String(accumulatedTextBytes))]
    }
}

/// A report is rebuilt from allowlisted values, never from an error description,
/// settings dump, account identity, response body or log. It lives only in memory.
struct ChatGPTDiagnosticReport: Equatable, Sendable {
    let text: String

    init(diagnostics: ChatGPTDiagnostics, settings: AppSettings,
         appVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
         appBuild: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) {
        let version = Self.numeric(appVersion, pattern: #"^[0-9]{1,4}(\.[0-9]{1,4}){1,3}$"#)
        let build = Self.numeric(appBuild, pattern: #"^[0-9]{1,12}$"#)
        let output = ["schema", "json", "prompt"].contains(settings.cloudOutput) ? settings.cloudOutput : "other"
        let reasoning = ["auto", "none", "minimal", "low", "medium", "high", "xhigh", "max"].contains(settings.cloudReasoning) ? settings.cloudReasoning : "other"
        let fields = [("report_version", "1"), ("app_version", version), ("app_build", build),
                      ("provider", "chatgpt"), ("probe", "check-cloud"),
                      ("output_mode", output), ("reasoning", reasoning)] + diagnostics.fields
        text = "Posle ChatGPT diagnostics\n" + fields.map { "\($0.0)=\($0.1)" }.joined(separator: "\n") + "\n"
    }

    private static func numeric(_ value: String?, pattern: String) -> String {
        guard let value, value.utf8.count <= 24,
              value.range(of: pattern, options: .regularExpression) == value.startIndex..<value.endIndex else { return "unknown" }
        return value
    }

    @MainActor @discardableResult
    func copy(to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}
