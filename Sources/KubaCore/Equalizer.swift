import Foundation

public struct EQPreset: Codable, Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var gains: [Double]

    public init(name: String, gains: [Double]) {
        self.name = name
        self.gains = gains
    }
}

/// Equalizador gráfico de N bandas (padrão: 10 bandas, ±12 dB).
public struct Equalizer: Codable, Equatable, Sendable {
    public static let defaultFrequencies: [Double] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    public var frequencies: [Double]
    public var gains: [Double]
    public var minGain: Double
    public var maxGain: Double
    /// Passo suportado pelo fone (ex.: 1 dB ou 0,5 dB).
    public var step: Double
    /// Fator Q dos filtros peaking usados para desenhar a curva.
    public var q: Double

    public init(frequencies: [Double] = Equalizer.defaultFrequencies,
                gains: [Double]? = nil,
                minGain: Double = -12, maxGain: Double = 12,
                step: Double = 1, q: Double = 1.41) {
        self.frequencies = frequencies
        self.gains = gains ?? Array(repeating: 0, count: frequencies.count)
        self.minGain = minGain
        self.maxGain = maxGain
        self.step = step
        self.q = q
    }

    /// Limita ao intervalo e arredonda para o passo do fone.
    public func quantize(_ gain: Double) -> Double {
        let clamped = min(max(gain, minGain), maxGain)
        guard step > 0 else { return clamped }
        return (clamped / step).rounded() * step
    }

    public mutating func setGain(_ gain: Double, at band: Int) {
        guard gains.indices.contains(band) else { return }
        gains[band] = quantize(gain)
    }

    public mutating func apply(_ preset: EQPreset) {
        for i in gains.indices {
            gains[i] = quantize(i < preset.gains.count ? preset.gains[i] : 0)
        }
    }

    /// Ganhos já quantizados no formato inteiro que o fone espera:
    /// valor = (ganho - offsetDb) / step. Ex.: -12..12 dB com offset -12 vira 0..24.
    public func encodedSteps(offsetDb: Double = 0) -> [Int] {
        gains.map { Int(((quantize($0) - offsetDb) / (step > 0 ? step : 1)).rounded()) }
    }

    /// Resposta aproximada em dB numa frequência (soma de filtros peaking RBJ).
    public func response(at frequency: Double, sampleRate: Double = 48_000) -> Double {
        var total = 0.0
        for (f0, gain) in zip(frequencies, gains) where gain != 0 && f0 < sampleRate / 2 {
            total += Equalizer.peakingResponseDb(f: frequency, f0: f0, gainDb: gain, q: q, fs: sampleRate)
        }
        return total
    }

    /// Pontos (freq, dB) em escala log entre 20 Hz e 20 kHz para desenhar o gráfico.
    public func curve(points: Int = 128) -> [(frequency: Double, db: Double)] {
        guard points > 1 else { return [] }
        let lo = log10(20.0), hi = log10(20_000.0)
        return (0..<points).map { i in
            let f = pow(10, lo + (hi - lo) * Double(i) / Double(points - 1))
            return (f, response(at: f))
        }
    }

    static func peakingResponseDb(f: Double, f0: Double, gainDb: Double, q: Double, fs: Double) -> Double {
        let a = pow(10, gainDb / 40)
        let w0 = 2 * Double.pi * f0 / fs
        let alpha = sin(w0) / (2 * q)
        let b0 = 1 + alpha * a, b1 = -2 * cos(w0), b2 = 1 - alpha * a
        let a0 = 1 + alpha / a, a1 = -2 * cos(w0), a2 = 1 - alpha / a
        let w = 2 * Double.pi * f / fs
        // |H(e^jw)|^2 calculado com cosseno/seno diretamente.
        func mag2(_ c0: Double, _ c1: Double, _ c2: Double) -> Double {
            let re = c0 + c1 * cos(w) + c2 * cos(2 * w)
            let im = -(c1 * sin(w) + c2 * sin(2 * w))
            return re * re + im * im
        }
        return 10 * log10(mag2(b0, b1, b2) / mag2(a0, a1, a2))
    }

    public static let builtInPresets: [EQPreset] = [
        EQPreset(name: "Plano", gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        EQPreset(name: "Graves+", gains: [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
        EQPreset(name: "Graves extremos", gains: [9, 8, 6, 3, 0, -1, -1, 0, 0, 0]),
        EQPreset(name: "Vocal", gains: [-2, -2, -1, 0, 2, 4, 4, 2, 0, -1]),
        EQPreset(name: "Agudos+", gains: [0, 0, 0, 0, 0, 1, 2, 4, 5, 6]),
        EQPreset(name: "V (balada)", gains: [5, 4, 2, 0, -2, -2, 0, 2, 4, 5]),
        EQPreset(name: "Podcast", gains: [-4, -3, -1, 1, 3, 4, 3, 1, -1, -3]),
        EQPreset(name: "Funk / Trap", gains: [7, 6, 4, 1, -1, 0, 1, 2, 3, 2]),
        EQPreset(name: "Rock", gains: [4, 3, 1, 0, -1, 0, 2, 3, 4, 4]),
    ]
}
