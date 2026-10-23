import Foundation

public enum DriverError: Error, Equatable, CustomStringConvertible {
    case unsupported(String)
    case unmappedValue(String)

    public var description: String {
        switch self {
        case .unsupported(let f): return "O perfil atual não tem o comando \"\(f)\"."
        case .unmappedValue(let v): return "O perfil não define um código para \"\(v)\"."
        }
    }
}

/// Transforma comandos de alto nível em bytes e notificações em eventos,
/// seguindo um `CommandProfile`.
public final class ProfileDriver {
    public let profile: CommandProfile
    private var sequence: UInt8 = 0
    private let eventPatterns: [(CommandProfile.EventRule, BytePattern)]

    public init(profile: CommandProfile) throws {
        self.profile = profile
        self.eventPatterns = try (profile.events ?? []).map { ($0, try BytePattern($0.match)) }
    }

    public func supports(_ command: HeadsetCommand) -> Bool {
        if case .raw = command { return true }
        return profile.commands[command.profileKey] != nil
    }

    private func nextSequence() -> UInt8 {
        defer { sequence &+= 1 }
        return sequence
    }

    private func code(_ map: [String: Int]?, _ key: String) throws -> Int {
        guard let value = map?[key] else { throw DriverError.unmappedValue(key) }
        return value
    }

    public func encode(_ command: HeadsetCommand) throws -> Data {
        if case .raw(let data) = command { return data }
        guard let source = profile.commands[command.profileKey] else {
            throw DriverError.unsupported(command.profileKey)
        }
        var params: [String: TemplateValue] = [:]
        switch command {
        case .setNoiseMode(let mode):
            params["mode"] = .int(try code(profile.noiseModes, mode.rawValue))
        case .setEqualizer(let gains):
            let spec = profile.equalizer ?? CommandProfile.EqualizerSpec()
            var eq = profile.makeEqualizer()
            for (i, g) in gains.enumerated() { eq.setGain(g, at: i) }
            guard let enc = IntEncoding(rawValue: spec.encoding) else {
                throw TemplateError.badToken(spec.encoding)
            }
            var bytes: [UInt8] = []
            for (i, v) in eq.encodedSteps(offsetDb: spec.offsetDb).enumerated() {
                bytes += try enc.encode(v, name: "banda \(i)")
            }
            params["gains"] = .bytes(Data(bytes))
            params["count"] = .int(eq.gains.count)
            for (i, v) in eq.encodedSteps(offsetDb: spec.offsetDb).enumerated() {
                params["g\(i)"] = .int(v)
            }
        case .setTouch(let binding):
            params["side"] = .int(try code(profile.touchSides, binding.side.rawValue))
            params["gesture"] = .int(try code(profile.touchGestures, binding.gesture.rawValue))
            params["action"] = .int(try code(profile.touchActions, binding.action.rawValue))
        case .setGameMode(let on):
            params["enabled"] = .int(on ? 1 : 0)
        case .requestBattery, .requestInfo, .raw:
            break
        }
        return try CommandTemplate(source).build(params, sequence: nextSequence())
    }

    public func decode(_ data: Data) -> HeadsetEvent {
        let bytes = Array(data)
        for (rule, pattern) in eventPatterns where pattern.matches(data) {
            if let event = makeEvent(rule, bytes) { return event }
        }
        return .unknown(data)
    }

    private func intField(_ field: CommandProfile.Field?, _ bytes: [UInt8]) -> Int? {
        guard let field, field.offset >= 0, field.offset < bytes.count else { return nil }
        let enc = IntEncoding(rawValue: field.type ?? "u8") ?? .u8
        guard var value = enc.decode(bytes[field.offset...]) else { return nil }
        if let mask = field.mask { value &= mask }
        return value
    }

    private func makeEvent(_ rule: CommandProfile.EventRule, _ bytes: [UInt8]) -> HeadsetEvent? {
        switch rule.type {
        case "battery":
            func level(_ key: String) -> Int? {
                guard let v = intField(rule.fields[key], bytes), (0...100).contains(v) else { return nil }
                return v
            }
            return .battery(BatteryStatus(left: level("left"), right: level("right"), caseLevel: level("case")))
        case "noiseMode":
            guard let raw = intField(rule.fields["mode"], bytes),
                  let name = profile.noiseModes?.first(where: { $0.value == raw })?.key,
                  let mode = NoiseMode(rawValue: name) else { return nil }
            return .noiseMode(mode)
        case "firmwareVersion":
            guard let field = rule.fields["version"], field.offset < bytes.count else { return nil }
            let end = min(bytes.count, field.offset + (field.length ?? (bytes.count - field.offset)))
            let slice = bytes[field.offset..<end]
            switch field.format ?? "dotted" {
            case "ascii":
                return .firmwareVersion(String(decoding: slice, as: UTF8.self)
                    .trimmingCharacters(in: .controlCharacters))
            case "hex":
                return .firmwareVersion(Data(slice).hexString(separator: ""))
            default:
                return .firmwareVersion(slice.map(String.init).joined(separator: "."))
            }
        case "ack":
            return .ack(rule.match)
        default:
            return nil
        }
    }
}
