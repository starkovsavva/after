import Foundation
#if SWIFT_PACKAGE
import XCTest
@testable import PosleCore
#endif

#if !SWIFT_PACKAGE
@main
#endif
struct TaskDueDateChecks {
    static func expect(_ value: @autoclosure () -> Bool, line: UInt = #line) {
        #if SWIFT_PACKAGE
        XCTAssertTrue(value(), line: line)
        #else
        precondition(value(), "Line \(line)")
        #endif
    }
    static func main() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        let monday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 20))!
        func date(_ raw: String, reference: Date? = monday) -> String? {
            TaskDueDate.resolve(raw, reference: reference, calendar: calendar).map { TaskDueDate.storage($0, calendar: calendar) }
        }
        expect(date("сегодня") == "2026-10-26")
        expect(date("завтра") == "2026-10-27")
        expect(date("к пятнице") == "2026-10-30")
        expect(date("до четверга") == "2026-10-29")
        expect(date("до пятницы") == "2026-10-30")
        expect(date("в понедельник") == "2026-10-26")
        expect(date("во вторник") == "2026-10-27")
        var buddhist = Calendar(identifier: .buddhist); buddhist.timeZone = calendar.timeZone
        expect(TaskDueDate.storage(monday, calendar: buddhist) == "2026-10-26")
        expect(TaskDueDate.resolve("2026-10-26", calendar: buddhist) == calendar.startOfDay(for: monday))
        expect(date("к пятнице", reference: nil) == nil)
        expect(date("сегодня", reference: nil) == nil)
        expect(date("не сегодня") == nil)
        expect(date("после пятницы") == nil)
        expect(date("в следующую пятницу") == nil)
        expect(date("2026-10-30", reference: nil) == "2026-10-30")
        expect(date("30.10.2026") == "2026-10-30")
        expect(date("30 октября 2026") == "2026-10-30")
        for invalid in ["2026-02-30", "31.02.2026", "00.10.2026", "2026-00-12", "2026-10-99", "2026-10-30 tomorrow"] {
            expect(date(invalid) == nil)
        }
        let beforeClockChange = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 3, day: 28, hour: 12))!
        var berlin = calendar; berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let after = TaskDueDate.resolve("завтра", reference: beforeClockChange, calendar: berlin)!
        expect(berlin.component(.hour, from: after) == 0)
        expect(TaskDueDate.display("когда-нибудь", reference: monday) == "когда-нибудь")
        print("PASS: anchored Russian deadlines, valid date storage, ambiguous legacy wording and DST")
    }
}

#if SWIFT_PACKAGE
final class TaskDueDateChecksTests: XCTestCase {
    func testContracts() throws { TaskDueDateChecks.main() }
}
#endif
