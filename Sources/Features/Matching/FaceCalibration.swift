import Foundation

/// Pure threshold-calibration math for the recognition engine.
///
/// The Face Test benchmark collects two score populations — genuine matches
/// (same person) and impostor matches (different people, *including people who
/// aren't the enrolled user*) — and this derives the operating threshold from
/// their observed false-accept / false-reject behavior instead of a hardcoded
/// guess. Precision-first: the default picks the lowest threshold that keeps
/// the false-accept rate at or below a strict target, because sharing a photo
/// with the wrong person is far worse than missing one.
///
/// No Vision/Core ML here — it operates on plain score arrays, so it is fully
/// unit-testable.
public enum FaceCalibration {

    /// Fraction of impostor pairs that would be (wrongly) accepted at `threshold`.
    public static func falseAcceptRate(threshold: Double, impostorScores: [Double]) -> Double {
        guard !impostorScores.isEmpty else { return 0 }
        let accepted = impostorScores.filter { $0 >= threshold }.count
        return Double(accepted) / Double(impostorScores.count)
    }

    /// Fraction of genuine pairs that would be (wrongly) rejected at `threshold`.
    public static func falseRejectRate(threshold: Double, genuineScores: [Double]) -> Double {
        guard !genuineScores.isEmpty else { return 0 }
        let rejected = genuineScores.filter { $0 < threshold }.count
        return Double(rejected) / Double(genuineScores.count)
    }

    public struct OperatingPoint: Equatable, Sendable {
        public let threshold: Double
        public let falseAcceptRate: Double
        public let falseRejectRate: Double
    }

    /// Candidate thresholds swept across the observed score range.
    private static func candidates(genuine: [Double], impostor: [Double], steps: Int = 200) -> [Double] {
        let all = genuine + impostor
        guard let lo = all.min(), let hi = all.max(), hi > lo else { return all.isEmpty ? [] : [all[0]] }
        return (0...steps).map { lo + (hi - lo) * Double($0) / Double(steps) }
    }

    /// Precision-first operating point: the LOWEST threshold whose false-accept
    /// rate is ≤ `targetFAR` (maximizing recall subject to the precision
    /// ceiling). Falls back to the max-FAR-minimizing threshold if the target
    /// is unachievable.
    public static func thresholdForTargetFAR(
        _ targetFAR: Double,
        genuineScores: [Double],
        impostorScores: [Double]
    ) -> OperatingPoint {
        let sweep = candidates(genuine: genuineScores, impostor: impostorScores)
        var best: OperatingPoint?
        for t in sweep {
            let far = falseAcceptRate(threshold: t, impostorScores: impostorScores)
            guard far <= targetFAR else { continue }
            let frr = falseRejectRate(threshold: t, genuineScores: genuineScores)
            // Lower threshold that still meets the FAR ceiling = better recall.
            if best == nil || t < best!.threshold {
                best = OperatingPoint(threshold: t, falseAcceptRate: far, falseRejectRate: frr)
            }
        }
        if let best { return best }
        // Target unachievable: pick the threshold with the smallest FAR (ties → higher threshold).
        let fallback = sweep.max { a, b in
            let fa = falseAcceptRate(threshold: a, impostorScores: impostorScores)
            let fb = falseAcceptRate(threshold: b, impostorScores: impostorScores)
            return fa != fb ? fa > fb : a < b
        } ?? 1.0
        return OperatingPoint(
            threshold: fallback,
            falseAcceptRate: falseAcceptRate(threshold: fallback, impostorScores: impostorScores),
            falseRejectRate: falseRejectRate(threshold: fallback, genuineScores: genuineScores))
    }

    /// Equal-error-rate threshold — the point where FAR ≈ FRR. Useful as a
    /// descriptor-quality summary; NOT the shipping operating point (we ship
    /// tighter than EER on purpose).
    public static func equalErrorThreshold(
        genuineScores: [Double],
        impostorScores: [Double]
    ) -> OperatingPoint {
        let sweep = candidates(genuine: genuineScores, impostor: impostorScores)
        var best: OperatingPoint?
        var bestGap = Double.greatestFiniteMagnitude
        for t in sweep {
            let far = falseAcceptRate(threshold: t, impostorScores: impostorScores)
            let frr = falseRejectRate(threshold: t, genuineScores: genuineScores)
            let gap = abs(far - frr)
            if gap < bestGap {
                bestGap = gap
                best = OperatingPoint(threshold: t, falseAcceptRate: far, falseRejectRate: frr)
            }
        }
        return best ?? OperatingPoint(threshold: 0, falseAcceptRate: 0, falseRejectRate: 0)
    }

    /// Separation summary: mean genuine − mean impostor. Bigger is better; this
    /// is the single number that exposes "is the descriptor identity-grade at
    /// all". The V2/V3 feature-print sits near zero here on hard pairs.
    public static func separation(genuineScores: [Double], impostorScores: [Double]) -> Double {
        func mean(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }
        return mean(genuineScores) - mean(impostorScores)
    }
}
