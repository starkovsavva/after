import Foundation

/// Only typed transport metadata crosses this boundary. Unknown fields are
/// discarded; unknown enum values or missing/oversized counters reject copying.
package struct ChatGPTDiagnostics: Decodable, Equatable, Sendable {
    package let httpStatus: UInt16
    package let contentType: String
    package let wire: String
    package let responseBytes: UInt64
    package let events: UInt64
    package let outputTextDelta: UInt64
    package let outputTextDone: UInt64
    package let contentPartDone: UInt64
    package let outputItemDone: UInt64
    package let completed: UInt64
    package let otherEvents: UInt64
    package let terminalStatus: String
    package let terminalOutput: String
    package let terminalOutputItems: UInt64
    package let terminalTextParts: UInt64
    package let terminalRefusalParts: UInt64
    package let terminalOtherParts: UInt64
    package let accumulatedTextBytes: UInt64

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
    package init(from decoder: Decoder) throws {
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

    package var fields: [(String, String)] {
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
