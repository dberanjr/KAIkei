import Foundation
import Testing
@testable import UsageCore

@Suite struct ChartScaleTests {
    @Test func niceTicksLandOnRoundNumbers() {
        #expect(NiceScale.ticks(max: 300_000) == [100_000, 200_000, 300_000])
        #expect(NiceScale.ticks(max: 850_000) == [500_000, 1_000_000])
        let cents = NiceScale.ticks(max: 0.073)
        #expect(cents.count == 3 && abs(cents[0] - 0.025) < 1e-12 && abs(cents[2] - 0.075) < 1e-12)
    }

    @Test func theTopTickCoversTheData() {
        for max in [1.0, 7.3, 123_456, 0.0042, 999_999] {
            let ticks = NiceScale.ticks(max: max)
            #expect(ticks.last! >= max, "max \(max)")
            #expect(NiceScale.top(for: max) == ticks.last!)
        }
    }

    @Test func noDataStillGivesAUsableAxis() {
        #expect(NiceScale.ticks(max: 0).isEmpty)
        #expect(NiceScale.top(for: 0) == 1)
        #expect(NiceScale.top(for: -5) == 1)
    }

    @Test func timeStepsGrowWithTheSpan() {
        #expect(TimeTicks.step(forSpan: 3_000, maxTicks: 5) == 600)         // 50 minutes: every 10 minutes
        #expect(TimeTicks.step(forSpan: 50_400, maxTicks: 5) == 10_800)     // 14 hours: every 3 hours
        #expect(TimeTicks.step(forSpan: 300, maxTicks: 6) == 60)
        // Zoomed in far enough, ticks drop below a minute so a 90 s window still has gridlines to read it by.
        #expect(TimeTicks.step(forSpan: 90, maxTicks: 6) == 15)
        #expect(TimeTicks.step(forSpan: 20, maxTicks: 6) == 5)
        #expect(TimeTicks.step(forSpan: 10 * 86_400, maxTicks: 5) == 172_800)
    }

    @Test func timeTicksAlignToTheClockNotToTheStart() {
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let start = Date(timeIntervalSince1970: 1_792_929_600 + 7 * 60)  // 12:07 UTC
        let offsets = TimeTicks.offsets(start: start, span: 3_000, step: 600, timeZone: utc.timeZone)
        #expect(offsets.first == 180)                 // 12:10
        #expect(offsets == [180, 780, 1_380, 1_980, 2_580])
    }

    @Test func clockAlignmentRespectsTheTimeZone() {
        let ist = TimeZone(secondsFromGMT: 19_800)!   // +5:30, so half-hour steps land on :00 and :30 local, not UTC
        let start = Date(timeIntervalSince1970: 1_792_929_600 + 60)  // 12:01 UTC = 17:31 IST
        let offsets = TimeTicks.offsets(start: start, span: 3_600, step: 3_600, timeZone: ist)
        #expect(offsets == [1_740])                   // 18:00 IST is 29 minutes after 17:31
    }
}
