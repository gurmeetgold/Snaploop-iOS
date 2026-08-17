import XCTest
@testable import SnapLoop

final class FaceCalibrationTests: XCTestCase {

    // Well-separated populations (a good identity model would look like this).
    private let genuine = [0.82, 0.85, 0.88, 0.90, 0.91, 0.93]
    private let impostor = [0.10, 0.20, 0.31, 0.40, 0.45, 0.52]

    func testFalseAcceptRateMonotonicallyDropsWithThreshold() {
        let low = FaceCalibration.falseAcceptRate(threshold: 0.3, impostorScores: impostor)
        let high = FaceCalibration.falseAcceptRate(threshold: 0.6, impostorScores: impostor)
        XCTAssertGreaterThan(low, high)
        XCTAssertEqual(FaceCalibration.falseAcceptRate(threshold: 0.6, impostorScores: impostor), 0, accuracy: 1e-9)
    }

    func testFalseRejectRateRisesWithThreshold() {
        let low = FaceCalibration.falseRejectRate(threshold: 0.70, genuineScores: genuine)
        let high = FaceCalibration.falseRejectRate(threshold: 0.92, genuineScores: genuine)
        XCTAssertLessThanOrEqual(low, high)
    }

    func testTargetFARPicksZeroImpostorThresholdForSeparableData() {
        let op = FaceCalibration.thresholdForTargetFAR(0.0, genuineScores: genuine, impostorScores: impostor)
        XCTAssertEqual(op.falseAcceptRate, 0, accuracy: 1e-9)
        // Should still admit most genuine matches — threshold below the genuine cluster.
        XCTAssertLessThan(op.threshold, 0.82)
        XCTAssertLessThan(op.falseRejectRate, 0.2)
    }

    func testPrecisionFirstPrefersLowerThresholdAmongThoseMeetingFARCeiling() {
        // Two thresholds both hit FAR=0; the calibrator should pick the lower
        // one (better recall) rather than an arbitrarily high one.
        let op = FaceCalibration.thresholdForTargetFAR(0.0, genuineScores: genuine, impostorScores: impostor)
        XCTAssertGreaterThan(op.threshold, 0.52) // above impostor max
        XCTAssertLessThanOrEqual(op.threshold, 0.82) // at/below genuine min
    }

    func testEqualErrorThresholdSitsBetweenClusters() {
        let op = FaceCalibration.equalErrorThreshold(genuineScores: genuine, impostorScores: impostor)
        XCTAssertGreaterThan(op.threshold, 0.52)
        XCTAssertLessThan(op.threshold, 0.82)
    }

    func testSeparationIsPositiveForGoodModelAndNearZeroForBad() {
        XCTAssertGreaterThan(FaceCalibration.separation(genuineScores: genuine, impostorScores: impostor), 0.3)
        // A weak descriptor: genuine and impostor overlap heavily.
        let weakGenuine = [0.50, 0.55, 0.60, 0.62]
        let weakImpostor = [0.48, 0.52, 0.58, 0.61]
        XCTAssertLessThan(FaceCalibration.separation(genuineScores: weakGenuine, impostorScores: weakImpostor), 0.1)
    }

    func testUnachievableTargetFallsBackToLowestFARThreshold() {
        // Overlapping data where FAR can't reach 0 without rejecting everything.
        let g = [0.5, 0.6]
        let i = [0.55, 0.65]
        let op = FaceCalibration.thresholdForTargetFAR(0.0, genuineScores: g, impostorScores: i)
        XCTAssertGreaterThanOrEqual(op.threshold, 0.65)  // high enough to exclude impostors
    }
}
