import Foundation
import Accelerate

public enum EchoCanceller {

    public struct Outcome {
        public let samples: [Float]
        public let bulkDelaySeconds: Double
        public let echoReductionDB: Double
    }

    private static let blockSize = 256
    private static let fftSize = 512
    private static let partitions = 16

    private static let envelopeFrameSeconds = 0.010
    private static let maxLagSeconds = 2.5
    private static let chunkSeconds = 60.0
    private static let realignSeconds = 0.040
    private static let marginSeconds = 0.064
    private static let minDelayCorrelation: Float = 0.25

    private static let stepPass1: Float = 0.5
    private static let stepPass2: Float = 0.25
    private static let refActiveFloor: Float = 1e-4

    public static func cancel(mic: [Float], reference: [Float], sampleRate: Double) -> Outcome? {
        guard sampleRate > 0 else { return nil }
        let minSamples = Int(3 * sampleRate)
        guard mic.count >= minSamples, reference.count >= minSamples else { return nil }

        let frame = max(1, Int(envelopeFrameSeconds * sampleRate))
        let micEnv = envelope(mic, frame: frame)
        let refEnv = envelope(reference, frame: frame)
        let maxLag = max(1, Int(maxLagSeconds / envelopeFrameSeconds))
        guard let global = bestLag(micEnv, refEnv, range: 0..<micEnv.count, maxLag: maxLag),
              global.correlation >= minDelayCorrelation else { return nil }

        let aligned = alignedReference(reference, toMicLength: mic.count,
                                       micEnv: micEnv, refEnv: refEnv,
                                       globalLagFrames: global.lag,
                                       frame: frame, sampleRate: sampleRate)

        guard let filter = PartitionedFilter(blockSize: blockSize, fftSize: fftSize, partitions: partitions) else { return nil }
        let (refActive, refLevel) = referenceActivity(aligned, blockCount: (mic.count + blockSize - 1) / blockSize)
        var discard = [Float]()
        guard let pass1Errors = filter.run(mic: mic, reference: aligned, step: stepPass1, referenceLevel: refLevel,
                                           refActive: refActive, adaptMask: nil, into: &discard) else { return nil }
        let mask = adaptationMask(pass1Errors: pass1Errors, refActive: refActive)
        var out = [Float](repeating: 0, count: mic.count)
        guard filter.run(mic: mic, reference: aligned, step: stepPass2, referenceLevel: refLevel,
                         refActive: refActive, adaptMask: mask, into: &out) != nil else { return nil }

        let reduction = filter.lastRunEchoReductionDB
        guard reduction > 3 else { return nil }
        return Outcome(samples: out,
                       bulkDelaySeconds: Double(global.lag * frame) / sampleRate,
                       echoReductionDB: reduction)
    }

    private static func referenceActivity(_ reference: [Float], blockCount: Int) -> (active: [Bool], level: Float) {
        var energies = [Float](repeating: 0, count: blockCount)
        reference.withUnsafeBufferPointer { buf in
            for i in 0..<blockCount {
                let s = i * blockSize
                let n = min(blockSize, reference.count - s)
                guard n > 0 else { break }
                var ms: Float = 0
                vDSP_measqv(buf.baseAddress! + s, 1, &ms, vDSP_Length(n))
                energies[i] = ms
            }
        }
        let peak = energies.max() ?? 0
        let threshold = peak * refActiveFloor
        let active = energies.map { $0 > threshold }
        let activeEnergies = zip(energies, active).compactMap { $1 ? $0 : nil }
        let level = activeEnergies.isEmpty ? 0 : activeEnergies.reduce(0, +) / Float(activeEnergies.count)
        return (active, level)
    }

    private static func adaptationMask(pass1Errors: [Float], refActive: [Bool]) -> [Bool] {
        let residuals = zip(pass1Errors, refActive).compactMap { $1 ? $0 : nil }.sorted()
        guard !residuals.isEmpty else { return refActive }
        let median = residuals[residuals.count / 2]
        let nearThreshold = max(median * 6, Float.leastNormalMagnitude)
        return (0..<pass1Errors.count).map { refActive[$0] && pass1Errors[$0] <= nearThreshold }
    }

    static func envelope(_ samples: [Float], frame: Int) -> [Float] {
        guard frame > 0, !samples.isEmpty else { return [] }
        var out = [Float]()
        out.reserveCapacity(samples.count / frame + 1)
        var i = 0
        while i < samples.count {
            let end = min(i + frame, samples.count)
            var meanSquare: Float = 0
            samples.withUnsafeBufferPointer { buf in
                vDSP_measqv(buf.baseAddress! + i, 1, &meanSquare, vDSP_Length(end - i))
            }
            out.append(meanSquare.squareRoot())
            i = end
        }
        return out
    }

    static func bestLag(_ micEnv: [Float], _ refEnv: [Float],
                        range: Range<Int>, maxLag: Int) -> (lag: Int, correlation: Float)? {
        let lo = max(0, range.lowerBound), hi = min(micEnv.count, range.upperBound)
        guard hi - lo > 8 else { return nil }
        func centered(_ env: [Float], _ a: Int, _ b: Int) -> [Float] {
            guard b > a else { return [] }
            var slice = Array(env[a..<b])
            var mean: Float = 0
            vDSP_meanv(slice, 1, &mean, vDSP_Length(slice.count))
            var negMean = -mean
            vDSP_vsadd(slice, 1, &negMean, &slice, 1, vDSP_Length(slice.count))
            return slice
        }
        let rLo = max(0, lo - maxLag)
        let rHi = min(refEnv.count, hi + maxLag)
        let m = centered(micEnv, lo, hi)
        let r = centered(refEnv, rLo, rHi)
        guard !m.isEmpty, !r.isEmpty else { return nil }

        var mNorm: Float = 0, rNorm: Float = 0
        vDSP_svesq(m, 1, &mNorm, vDSP_Length(m.count))
        vDSP_svesq(r, 1, &rNorm, vDSP_Length(r.count))
        let denominator = (mNorm * rNorm).squareRoot()
        guard denominator > 0 else { return nil }

        var best: (lag: Int, correlation: Float)?
        for lag in -maxLag...maxLag {
            let rStart = lo - lag - rLo
            let iMin = max(0, -rStart)
            let iMax = min(m.count, r.count - rStart)
            guard iMax - iMin >= m.count / 2 else { continue }
            var dot: Float = 0
            m.withUnsafeBufferPointer { mb in
                r.withUnsafeBufferPointer { rb in
                    vDSP_dotpr(mb.baseAddress! + iMin, 1, rb.baseAddress! + rStart + iMin, 1, &dot, vDSP_Length(iMax - iMin))
                }
            }
            let c = dot / denominator
            if best == nil || c > best!.correlation { best = (lag, c) }
        }
        return best
    }

    private static func alignedReference(_ reference: [Float], toMicLength length: Int,
                                         micEnv: [Float], refEnv: [Float],
                                         globalLagFrames: Int, frame: Int,
                                         sampleRate: Double) -> [Float] {
        let margin = Int(marginSeconds * sampleRate)
        let realignFrames = max(1, Int(realignSeconds * sampleRate) / frame)
        let chunkFrames = max(1, Int(chunkSeconds * sampleRate) / frame)
        let maxLag = max(1, Int(maxLagSeconds / envelopeFrameSeconds))
        let refPeak = refEnv.max() ?? 0

        var out = [Float](repeating: 0, count: length)
        var currentLag = globalLagFrames
        var chunkStart = 0
        while chunkStart < micEnv.count {
            let chunkEnd = min(chunkStart + chunkFrames, micEnv.count)
            let chunkRefLoud = refEnv[max(0, chunkStart - maxLag)..<min(refEnv.count, chunkEnd)].max() ?? 0
            if chunkRefLoud > refPeak * 0.05,
               let est = bestLag(micEnv, refEnv, range: chunkStart..<chunkEnd, maxLag: maxLag),
               est.correlation >= minDelayCorrelation,
               abs(est.lag - currentLag) >= realignFrames {
                currentLag = est.lag
            }
            let shift = currentLag * frame - margin
            let sampleStart = chunkStart * frame
            let sampleEnd = min(chunkEnd * frame, length)
            for n in sampleStart..<sampleEnd {
                let src = n - shift
                out[n] = (src >= 0 && src < reference.count) ? reference[src] : 0
            }
            chunkStart = chunkEnd
        }
        return out
    }
}

private final class PartitionedFilter {
    private let B: Int
    private let N: Int
    private let P: Int

    private let forward: vDSP.DiscreteFourierTransform<Float>
    private let inverse: vDSP.DiscreteFourierTransform<Float>

    private var wRe: [[Float]], wIm: [[Float]]
    private var xRe: [[Float]], xIm: [[Float]]
    private var ringHead = 0

    private(set) var lastRunEchoReductionDB: Double = 0
    private(set) var lastRunStats: (weightResets: Int, rawBlocks: Int, adaptedBlocks: Int) = (0, 0, 0)

    init?(blockSize: Int, fftSize: Int, partitions: Int) {
        guard fftSize == 2 * blockSize,
              let f = try? vDSP.DiscreteFourierTransform(previous: nil, count: fftSize, direction: .forward,
                                                         transformType: .complexComplex, ofType: Float.self),
              let i = try? vDSP.DiscreteFourierTransform(previous: nil, count: fftSize, direction: .inverse,
                                                         transformType: .complexComplex, ofType: Float.self)
        else { return nil }
        B = blockSize; N = fftSize; P = partitions
        forward = f; inverse = i
        wRe = Array(repeating: [Float](repeating: 0, count: fftSize), count: partitions)
        wIm = wRe; xRe = wRe; xIm = wRe
    }

    func run(mic: [Float], reference: [Float], step: Float, referenceLevel: Float,
             refActive: [Bool], adaptMask: [Bool]?, into output: inout [Float]) -> [Float]? {
        let writeOutput = output.count >= mic.count
        let epsilon = max(0.01 * Float(P) * Float(N) * referenceLevel, 1e-12)
        for p in 0..<P { xRe[p].replaceSubrange(0..<N, with: repeatElement(0, count: N))
                         xIm[p].replaceSubrange(0..<N, with: repeatElement(0, count: N)) }
        ringHead = 0

        let count = mic.count
        let blocks = (count + B - 1) / B
        guard refActive.count >= blocks, refActive.contains(true) else { return nil }
        var errorEnergies = [Float](repeating: 0, count: blocks)

        var timeRe = [Float](repeating: 0, count: N)
        var timeIm = [Float](repeating: 0, count: N)
        var specRe = [Float](repeating: 0, count: N)
        var specIm = [Float](repeating: 0, count: N)
        var accRe = [Float](repeating: 0, count: N)
        var accIm = [Float](repeating: 0, count: N)
        var px = [Float](repeating: 0, count: N)
        var dBlock = [Float](repeating: 0, count: B)
        var eBlock = [Float](repeating: 0, count: B)
        var xPrev = [Float](repeating: 0, count: B)

        var resets = 0
        var sumMic = 0.0, sumOut = 0.0
        var stats = (weightResets: 0, rawBlocks: 0, adaptedBlocks: 0)
        defer { lastRunStats = stats }
        var emaD = 0.0, emaE = 0.0
        var emaWarmup = 0

        for i in 0..<blocks {
            let s = i * B
            let n = min(B, count - s)

            for k in 0..<B { timeRe[k] = xPrev[k] }
            for k in 0..<n { timeRe[B + k] = reference[s + k] }
            if n < B { for k in n..<B { timeRe[B + k] = 0 } }
            for k in 0..<B { xPrev[k] = timeRe[B + k] }
            vDSP.clear(&timeIm)
            forward.transform(inputReal: timeRe, inputImaginary: timeIm,
                              outputReal: &specRe, outputImaginary: &specIm)
            ringHead = (ringHead + P - 1) % P
            xRe[ringHead] = specRe
            xIm[ringHead] = specIm

            vDSP.clear(&accRe); vDSP.clear(&accIm)
            for p in 0..<P {
                let slot = (ringHead + p) % P
                complexMultiplyAccumulate(aRe: wRe[p], aIm: wIm[p],
                                          bRe: xRe[slot], bIm: xIm[slot],
                                          intoRe: &accRe, intoIm: &accIm, conjugateA: false)
            }
            inverse.transform(inputReal: accRe, inputImaginary: accIm,
                              outputReal: &timeRe, outputImaginary: &timeIm)
            let scale = 1 / Float(N)

            for k in 0..<n { dBlock[k] = mic[s + k] }
            if n < B { for k in n..<B { dBlock[k] = 0 } }
            for k in 0..<B { eBlock[k] = dBlock[k] - timeRe[B + k] * scale }

            var eEnergy: Float = 0, dEnergy: Float = 0
            vDSP_svesq(eBlock, 1, &eEnergy, vDSP_Length(B))
            vDSP_svesq(dBlock, 1, &dEnergy, vDSP_Length(B))

            var mustReset = false
            if !eEnergy.isFinite {
                resets += 1
                if resets > 2 { return nil }
                mustReset = true
            } else if refActive[i] {
                emaD = 0.95 * emaD + 0.05 * Double(dEnergy)
                emaE = 0.95 * emaE + 0.05 * Double(eEnergy)
                emaWarmup += 1
                if emaWarmup > 40, emaE > 4 * emaD {
                    mustReset = true
                    emaE = emaD
                }
            }
            if mustReset {
                for p in 0..<P {
                    vDSP.clear(&wRe[p]); vDSP.clear(&wIm[p])
                }
                for k in 0..<B { eBlock[k] = dBlock[k] }
                eEnergy = dEnergy
                stats.weightResets += 1
            }

            let emitRaw = eEnergy > 1.5 * dEnergy
            if emitRaw { stats.rawBlocks += 1 }
            let outEnergy = emitRaw ? dEnergy : eEnergy
            if writeOutput {
                for k in 0..<n { output[s + k] = emitRaw ? dBlock[k] : eBlock[k] }
            }
            errorEnergies[i] = outEnergy

            if refActive[i] {
                sumMic += Double(dEnergy)
                sumOut += Double(outEnergy)
            }

            guard adaptMask?[i] ?? refActive[i], eEnergy <= 2 * dEnergy else { continue }
            stats.adaptedBlocks += 1

            vDSP.clear(&timeRe); vDSP.clear(&timeIm)
            for k in 0..<B { timeRe[B + k] = eBlock[k] }
            forward.transform(inputReal: timeRe, inputImaginary: timeIm,
                              outputReal: &specRe, outputImaginary: &specIm)

            vDSP.clear(&px)
            for p in 0..<P {
                let slot = (ringHead + p) % P
                xRe[slot].withUnsafeBufferPointer { re in
                    xIm[slot].withUnsafeBufferPointer { im in
                        px.withUnsafeMutableBufferPointer { out in
                            for k in 0..<N { out[k] += re[k] * re[k] + im[k] * im[k] }
                        }
                    }
                }
            }
            var pxMean: Float = 0
            vDSP_meanv(px, 1, &pxMean, vDSP_Length(N))
            let eps = max(1e-3 * pxMean, epsilon)

            for p in 0..<P {
                let slot = (ringHead + p) % P
                updatePartition(p: p, slot: slot, eRe: specRe, eIm: specIm,
                                px: px, eps: eps, step: step)
            }

            constrainPartition(i % P, timeRe: &timeRe, timeIm: &timeIm,
                               specRe: &specRe, specIm: &specIm)
        }

        lastRunEchoReductionDB = sumOut > 0 ? 10 * log10(sumMic / sumOut) : 0
        return errorEnergies
    }

    private func updatePartition(p: Int, slot: Int, eRe: [Float], eIm: [Float],
                                 px: [Float], eps: Float, step: Float) {
        wRe[p].withUnsafeMutableBufferPointer { wr in
            wIm[p].withUnsafeMutableBufferPointer { wi in
                xRe[slot].withUnsafeBufferPointer { xr in
                    xIm[slot].withUnsafeBufferPointer { xi in
                        px.withUnsafeBufferPointer { pxb in
                            eRe.withUnsafeBufferPointer { er in
                                eIm.withUnsafeBufferPointer { ei in
                                    for k in 0..<N {
                                        let norm = step / (pxb[k] + eps)
                                        let gr = xr[k] * er[k] + xi[k] * ei[k]
                                        let gi = xr[k] * ei[k] - xi[k] * er[k]
                                        wr[k] += norm * gr
                                        wi[k] += norm * gi
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func constrainPartition(_ p: Int, timeRe: inout [Float], timeIm: inout [Float],
                                    specRe: inout [Float], specIm: inout [Float]) {
        inverse.transform(inputReal: wRe[p], inputImaginary: wIm[p],
                          outputReal: &timeRe, outputImaginary: &timeIm)
        var scale = 1 / Float(N)
        vDSP_vsmul(timeRe, 1, &scale, &timeRe, 1, vDSP_Length(N))
        vDSP_vsmul(timeIm, 1, &scale, &timeIm, 1, vDSP_Length(N))
        for k in B..<N { timeRe[k] = 0; timeIm[k] = 0 }
        forward.transform(inputReal: timeRe, inputImaginary: timeIm,
                          outputReal: &specRe, outputImaginary: &specIm)
        wRe[p] = specRe
        wIm[p] = specIm
    }

    private func complexMultiplyAccumulate(aRe: [Float], aIm: [Float],
                                           bRe: [Float], bIm: [Float],
                                           intoRe: inout [Float], intoIm: inout [Float],
                                           conjugateA: Bool) {
        aRe.withUnsafeBufferPointer { ar in
            aIm.withUnsafeBufferPointer { ai in
                bRe.withUnsafeBufferPointer { br in
                    bIm.withUnsafeBufferPointer { bi in
                        intoRe.withUnsafeMutableBufferPointer { or2 in
                            intoIm.withUnsafeMutableBufferPointer { oi in
                                if conjugateA {
                                    for k in 0..<N {
                                        or2[k] += ar[k] * br[k] + ai[k] * bi[k]
                                        oi[k] += ar[k] * bi[k] - ai[k] * br[k]
                                    }
                                } else {
                                    for k in 0..<N {
                                        or2[k] += ar[k] * br[k] - ai[k] * bi[k]
                                        oi[k] += ar[k] * bi[k] + ai[k] * br[k]
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
