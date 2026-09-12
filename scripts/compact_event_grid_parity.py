from pathlib import Path

ROOT = Path('.')

def read(path):
    return (ROOT / path).read_text()

def write(path, text):
    (ROOT / path).write_text(text)

def replace_once(text, old, new, label):
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one match, found {count}")
    return text.replace(old, new, 1)

rel = 'Sources/Core/DateFormatting.swift'
s = read(rel)
old = '''    /// "Aug 15 – Aug 18, 2026" style range (collapses shared year/month sensibly
    /// via the OS interval formatter). Canonical Events pass their persisted
    /// Event timezone so every participant sees the organizer-selected civil
    /// dates even after travelling to another timezone.
    public static func range(_ start: Date, _ end: Date, timeZone: TimeZone? = nil) -> String {
        let f = DateIntervalFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        if let timeZone { f.timeZone = timeZone }
        return f.string(from: start, to: end)
            .replacingOccurrences(of: " ", with: "\\u{00A0}")
    }
'''
new = '''    /// Compact Event-card range, e.g. "Aug 15 – Aug 18". Years are deliberately
    /// omitted to preserve card symmetry; canonical Events still pass their persisted
    /// Event timezone so every participant sees the organizer-selected civil dates.
    public static func range(_ start: Date, _ end: Date, timeZone: TimeZone? = nil) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        if let timeZone { formatter.timeZone = timeZone }
        let startText = formatter.string(from: start)
        let endText = formatter.string(from: end)
        if Calendar.current.isDate(start, inSameDayAs: end) { return startText }
        return "\\(startText) – \\(endText)"
            .replacingOccurrences(of: " ", with: "\\u{00A0}")
    }
'''
s = replace_once(s, old, new, 'compact event range')
write(rel, s)

for rel in [
    'Sources/Features/MyPhotos/MyPhotosView.swift',
    'Sources/Features/MyPhotos/AllMyPhotosView.swift',
]:
    s = read(rel)
    s = replace_once(s, '@State private var columnCount = 2\n', '@State private var columnCount = 3\n', f'{rel} default three columns')
    write(rel, s)

test_rel = 'Tests/SnapLoopTests/CompactEventGridParityTests.swift'
write(test_rel, '''import XCTest
@testable import SnapLoop

final class CompactEventGridParityTests: XCTestCase {
    func testEventRangeOmitsYearAndKeepsBothEndpoints() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: DateComponents(year: 2026, month: 8, day: 15))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 8, day: 18))!
        let value = DateFormatting.range(start, end, timeZone: calendar.timeZone)
        XCTAssertTrue(value.contains("Aug"))
        XCTAssertTrue(value.contains("15"))
        XCTAssertTrue(value.contains("18"))
        XCTAssertFalse(value.contains("2026"))
    }

    func testEventRangeCollapsesSameDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: 2026, month: 8, day: 15))!
        let value = DateFormatting.range(date, date, timeZone: calendar.timeZone)
        XCTAssertFalse(value.contains("–"))
    }

    func testGallerySourcesDefaultToThreeColumns() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for relative in [
            "Sources/Features/MyPhotos/MyPhotosView.swift",
            "Sources/Features/MyPhotos/AllMyPhotosView.swift",
        ] {
            let source = try String(contentsOf: root.appendingPathComponent(relative))
            XCTAssertTrue(source.contains("@State private var columnCount = 3"), relative)
        }
    }
}
''')

print('iOS compact date and three-column parity applied')
