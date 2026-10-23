import Foundation

/// Descrição completa de como conversar com um fone, carregada de JSON.
/// Os perfis ficam em App/Resources/Profiles e podem ser importados/editados no app.
public struct CommandProfile: Codable, Equatable, Sendable {
    public struct Match: Codable, Equatable, Sendable {
        /// Prefixos do nome anunciado via Bluetooth (sem diferenciar maiúsculas).
        public var namePrefixes: [String]
        public var serviceUUIDs: [String]

        public init(namePrefixes: [String] = [], serviceUUIDs: [String] = []) {
            self.namePrefixes = namePrefixes
            self.serviceUUIDs = serviceUUIDs
        }
    }

    public struct Transport: Codable, Equatable, Sendable {
        public var service: String
        public var write: String
        public var notify: String
        public var writeWithResponse: Bool

        public init(service: String, write: String, notify: String, writeWithResponse: Bool = false) {
            self.service = service
            self.write = write
            self.notify = notify
            self.writeWithResponse = writeWithResponse
        }
    }

    public struct EqualizerSpec: Codable, Equatable, Sendable {
        public var frequencies: [Double]
        public var minGain: Double
        public var maxGain: Double
        public var step: Double
        /// Ganho (dB) que corresponde ao valor 0 enviado ao fone.
        public var offsetDb: Double
        /// "i8", "u8", "i16le"... formato de cada banda.
        public var encoding: String

        public init(frequencies: [Double] = Equalizer.defaultFrequencies,
                    minGain: Double = -12, maxGain: Double = 12, step: Double = 1,
                    offsetDb: Double = 0, encoding: String = "i8") {
            self.frequencies = frequencies
            self.minGain = minGain
            self.maxGain = maxGain
            self.step = step
            self.offsetDb = offsetDb
            self.encoding = encoding
        }
    }

    public struct Field: Codable, Equatable, Sendable {
        public var offset: Int
        public var type: String?
        public var length: Int?
        /// Máscara aplicada ao valor (ex.: 127 para tirar o bit de "carregando").
        public var mask: Int?
        /// "dotted" (1.2.3), "ascii" ou "hex" para versões.
        public var format: String?

        public init(offset: Int, type: String? = nil, length: Int? = nil, mask: Int? = nil, format: String? = nil) {
            self.offset = offset
            self.type = type
            self.length = length
            self.mask = mask
            self.format = format
        }
    }

    public struct EventRule: Codable, Equatable, Sendable {
        /// "battery", "noiseMode", "firmwareVersion" ou "ack".
        public var type: String
        public var match: String
        public var fields: [String: Field]

        public init(type: String, match: String, fields: [String: Field] = [:]) {
            self.type = type
            self.match = match
            self.fields = fields
        }

        /// `fields` pode faltar no JSON (ex.: eventos de confirmação).
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try c.decode(String.self, forKey: .type)
            match = try c.decode(String.self, forKey: .match)
            fields = try c.decodeIfPresent([String: Field].self, forKey: .fields) ?? [:]
        }
    }

    public struct OTASpec: Codable, Equatable, Sendable {
        public var chunkSize: Int
        public var start: String
        public var chunk: String
        public var finish: String
        /// Padrão da resposta de confirmação de cada etapa.
        public var ackMatch: String
        public var ackTimeoutMs: Int
        public var retries: Int
        public var minBattery: Int

        public init(chunkSize: Int = 180, start: String, chunk: String, finish: String,
                    ackMatch: String, ackTimeoutMs: Int = 3000, retries: Int = 3, minBattery: Int = 50) {
            self.chunkSize = chunkSize
            self.start = start
            self.chunk = chunk
            self.finish = finish
            self.ackMatch = ackMatch
            self.ackTimeoutMs = ackTimeoutMs
            self.retries = retries
            self.minBattery = minBattery
        }
    }

    public var id: String
    public var name: String
    /// false enquanto os bytes não forem confirmados num fone de verdade.
    public var verified: Bool
    public var notes: String?
    public var match: Match
    public var transport: Transport
    public var equalizer: EqualizerSpec?
    public var noiseModes: [String: Int]?
    public var touchSides: [String: Int]?
    public var touchGestures: [String: Int]?
    public var touchActions: [String: Int]?
    public var commands: [String: String]
    public var events: [EventRule]?
    public var ota: OTASpec?

    public init(id: String, name: String, verified: Bool = false, notes: String? = nil,
                match: Match = Match(), transport: Transport, equalizer: EqualizerSpec? = nil,
                noiseModes: [String: Int]? = nil, touchSides: [String: Int]? = nil,
                touchGestures: [String: Int]? = nil, touchActions: [String: Int]? = nil,
                commands: [String: String] = [:], events: [EventRule]? = nil, ota: OTASpec? = nil) {
        self.id = id
        self.name = name
        self.verified = verified
        self.notes = notes
        self.match = match
        self.transport = transport
        self.equalizer = equalizer
        self.noiseModes = noiseModes
        self.touchSides = touchSides
        self.touchGestures = touchGestures
        self.touchActions = touchActions
        self.commands = commands
        self.events = events
        self.ota = ota
    }

    public static func load(from data: Data) throws -> CommandProfile {
        try JSONDecoder().decode(CommandProfile.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// O perfil serve para este aparelho? (nome anunciado ou serviços encontrados)
    public func matches(name: String?, services: [String]) -> Bool {
        let lowered = name?.lowercased() ?? ""
        if match.namePrefixes.contains(where: { lowered.hasPrefix($0.lowercased()) }) { return true }
        let wanted = Set(match.serviceUUIDs.map(BLEUUID.normalize))
        return !wanted.isDisjoint(with: services.map(BLEUUID.normalize))
    }

    public var supportedFeatures: Set<String> { Set(commands.keys) }

    public func makeEqualizer() -> Equalizer {
        guard let spec = equalizer else { return Equalizer() }
        return Equalizer(frequencies: spec.frequencies, minGain: spec.minGain,
                         maxGain: spec.maxGain, step: spec.step)
    }
}

public enum BLEUUID {
    /// "ae00" e "0000AE00-0000-1000-8000-00805F9B34FB" viram a mesma coisa.
    public static func normalize(_ uuid: String) -> String {
        let up = uuid.uppercased()
        let base = "-0000-1000-8000-00805F9B34FB"
        if up.count == 36, up.hasPrefix("0000"), up.hasSuffix(base) {
            return String(up.dropFirst(4).prefix(4))
        }
        return up
    }
}
