import Foundation
import Testing
@testable import Peaky

/// The bars split sound into bass / low-mid / high-mid / treble. Feed pure tones, see which bar moves.
@Suite struct LiveBars {
    func tone(_ hz: Double, amplitude: Float = 0.5, rate: Double = 48000, count: Int = 4800) -> [Float] {
        (0..<count).map { amplitude * Float(sin(2 * .pi * hz * Double($0) / rate)) }
    }

    func levels(_ samples: [Float]) -> [Float] {
        var m = BandMeter(sampleRate: 48000)
        var out: [Float] = []
        for chunk in stride(from: 0, to: samples.count, by: 480) {   // 10 ms buffers, like the tap delivers
            m.feed(Array(samples[chunk..<min(chunk + 480, samples.count)]))
            out = m.levels()
        }
        return out
    }

    @Test func eachToneLightsItsOwnBar() {
        for (bar, hz) in [80.0, 400, 1500, 6000].enumerated() {
            let l = levels(tone(hz))
            #expect(l[bar] > 0.8, "\(hz) Hz → \(l)")
            for other in 0..<4 where other != bar { #expect(l[other] < 0.3, "\(hz) Hz → \(l)") }
        }
    }

    @Test func silenceIsFlat() {
        #expect(levels([Float](repeating: 0, count: 4800)) == [0, 0, 0, 0])
        #expect(levels(tone(400, amplitude: 0.00001)).allSatisfy { $0 == 0 })
    }

    @Test func bassAndTrebleTogether() {
        let mix = zip(tone(80), tone(6000)).map { $0 + $1 }
        let l = levels(mix)
        #expect(l[0] > 0.8 && l[3] > 0.8, "\(l)")
    }
}
