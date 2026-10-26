import Foundation
import Testing
@testable import UsageCore

@Suite struct HourlyProfileTests {
    func profile(_ spikes: [Int: Double]) -> HourlyProfile {
        var costs = [Double](repeating: 0, count: 24)
        for (h, v) in spikes { costs[h] = v }
        return HourlyProfile(costs: costs)
    }

    @Test func totalsAndFindsThePeakHour() {
        let p = profile([9: 1, 22: 6, 23: 3])
        #expect(p.total == 10 && p.peakHour == 22 && p.peakCost == 6)
    }

    @Test func anEmptyDayHasNoPeak() {
        let p = profile([:])
        #expect(p.peakHour == nil && p.total == 0 && p.activeHours == 0 && p.busiestWindow(hours: 3) == nil)
    }

    @Test func countsTheHoursWithAnySpend() { #expect(profile([1: 0.5, 2: 0, 3: 2]).activeHours == 2) }

    @Test func theBusiestWindowIsTheRunOfHoursWithTheMostSpend() throws {
        let w = try #require(profile([8: 0.5, 9: 2, 10: 3, 11: 1, 20: 4]).busiestWindow(hours: 3))
        #expect(w.start == 9 && abs(w.share - 6.0 / 10.5) < 1e-12)
    }

    @Test func aWindowWrapsPastMidnightBecauseTheDayIsACircle() throws {
        let w = try #require(profile([23: 5, 0: 4, 1: 3, 12: 1]).busiestWindow(hours: 3))
        #expect(w.start == 23 && abs(w.share - 12.0 / 13.0) < 1e-12)
    }

    @Test func labelsHoursTheWayPeopleSayThem() {
        #expect(HourlyProfile.label(0) == "12 AM" && HourlyProfile.label(12) == "12 PM" && HourlyProfile.label(22) == "10 PM" && HourlyProfile.label(5) == "5 AM")
    }

    @Test func padsOrTrimsToTwentyFourHours() {
        #expect(HourlyProfile(costs: [1, 2]).costs.count == 24 && HourlyProfile(costs: Array(repeating: 1, count: 30)).costs.count == 24)
    }
}

@Suite struct RoseGeometryTests {
    @Test func theLargestValueReachesTheOuterEdgeAndZeroStaysInTheHole() {
        #expect(Rose.radius(value: 10, peak: 10, inner: 20, outer: 100) == 100)
        #expect(Rose.radius(value: 0, peak: 10, inner: 20, outer: 100) == 20)
    }

    @Test func wedgeAreaIsInProportionToTheValueNotItsLength() {
        // Radius alone would exaggerate: a wedge with a quarter of the peak must have a quarter of the area.
        let r = Rose.radius(value: 2.5, peak: 10, inner: 20, outer: 100)
        let share = (r * r - 20 * 20) / (100 * 100 - 20 * 20)
        #expect(abs(share - 0.25) < 1e-12)
    }

    @Test func aValueAbovePeakIsCappedAndNothingToScaleGivesTheHole() {
        #expect(Rose.radius(value: 50, peak: 10, inner: 20, outer: 100) == 100)
        #expect(Rose.radius(value: 5, peak: 0, inner: 20, outer: 100) == 20)
    }

    @Test func hoursRunClockwiseFromTwelveAtTheTop() {
        #expect(Rose.startAngle(hour: 0) == 0 && Rose.startAngle(hour: 6) == 90 && Rose.startAngle(hour: 12) == 180 && Rose.startAngle(hour: 18) == 270)
        #expect(Rose.wedgeDegrees == 15)
    }

    @Test func aPointOnTheCircleSitsWhereAClockWould() {
        let top = Rose.point(center: (100, 100), radius: 50, degrees: 0), right = Rose.point(center: (100, 100), radius: 50, degrees: 90)
        #expect(abs(top.x - 100) < 1e-9 && abs(top.y - 50) < 1e-9)     // up on screen is smaller y
        #expect(abs(right.x - 150) < 1e-9 && abs(right.y - 100) < 1e-9)
    }
}
