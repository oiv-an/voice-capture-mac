import Accelerate
import Foundation

/// Torchaudio-compatible power mel: periodic Hann, HTK, no normalization, center=false.
final class GigaAMFeatures {
    private let fft: OpaquePointer
    private let window: [Float]
    private let filters: [[Float]]

    init() throws {
        guard let setup = vDSP_DFT_zop_CreateSetup(nil, 320, .FORWARD) else {
            throw GigaAMError.message("Не удалось создать DFT для GigaAM")
        }
        fft = setup
        window = (0..<320).map { 0.5 - 0.5 * cos(2 * Float.pi * Float($0) / 320) }
        let maxMel = 2595 * log10(1 + 8000.0 / 700)
        let points = (0..<66).map { 700 * (pow(10, Double($0) * maxMel / 65 / 2595) - 1) }
        filters = (0..<64).map { band in
            (0...160).map { bin in
                let hz = Double(bin) * 50
                return Float(
                    max(
                        0,
                        min(
                            (hz - points[band]) / (points[band + 1] - points[band]),
                            (points[band + 2] - hz) / (points[band + 2] - points[band + 1]))))
            }
        }
    }

    deinit { vDSP_DFT_DestroySetup(fft) }

    func compute(_ samples: [Float]) -> (values: [Float], frames: Int) {
        let frames = max(1, (samples.count - 320) / 160 + 1)
        let padded = samples + [Float](repeating: 0, count: max(0, 480_000 - samples.count))
        var values = [Float](repeating: log(1e-9), count: 64 * 2999)
        var input = [Float](repeating: 0, count: 320)
        let zeros = input
        var real = input
        var imaginary = input
        var power = [Float](repeating: 0, count: 161)
        // Include boundary frames containing the final samples, as in the padded reference.
        let populated = min(2999, (samples.count + 159) / 160)
        for frame in 0..<populated {
            for i in 0..<320 { input[i] = padded[frame * 160 + i] * window[i] }
            vDSP_DFT_Execute(fft, input, zeros, &real, &imaginary)
            for i in 0...160 { power[i] = real[i] * real[i] + imaginary[i] * imaginary[i] }
            for band in 0..<64 {
                var sum: Float = 0
                vDSP_dotpr(power, 1, filters[band], 1, &sum, 161)
                values[band * 2999 + frame] = log(min(1e9, max(1e-9, sum)))
            }
        }
        return (values, frames)
    }
}
