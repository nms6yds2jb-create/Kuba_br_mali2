import Foundation

/// Valor que preenche um campo `{nome}` de um modelo de comando.
public enum TemplateValue: Equatable, Sendable {
    case int(Int)
    case bytes(Data)
}

public enum TemplateError: Error, Equatable, CustomStringConvertible {
    case missingParameter(String)
    case badToken(String)
    case valueOutOfRange(String, Int)

    public var description: String {
        switch self {
        case .missingParameter(let n): return "Parâmetro ausente: \(n)"
        case .badToken(let t): return "Trecho inválido no modelo: \(t)"
        case .valueOutOfRange(let n, let v): return "Valor \(v) não cabe no campo \(n)"
        }
    }
}

public enum IntEncoding: String, Sendable {
    case u8, i8, u16le, u16be, i16le, i16be, u32le, u32be

    public var size: Int {
        switch self {
        case .u8, .i8: return 1
        case .u16le, .u16be, .i16le, .i16be: return 2
        case .u32le, .u32be: return 4
        }
    }

    public func encode(_ value: Int, name: String) throws -> [UInt8] {
        let signed = self == .i8 || self == .i16le || self == .i16be
        let bits = size * 8
        let lo = signed ? -(1 << (bits - 1)) : 0
        let hi = signed ? (1 << (bits - 1)) - 1 : (bits == 32 ? Int(UInt32.max) : (1 << bits) - 1)
        guard value >= lo && value <= hi else { throw TemplateError.valueOutOfRange(name, value) }
        let raw = UInt32(truncatingIfNeeded: value)
        let le = (0..<size).map { UInt8(truncatingIfNeeded: raw >> (8 * UInt32($0))) }
        switch self {
        case .u16be, .i16be, .u32be: return le.reversed()
        default: return le
        }
    }

    public func decode(_ bytes: ArraySlice<UInt8>) -> Int? {
        guard bytes.count >= size else { return nil }
        var ordered = Array(bytes.prefix(size))
        if self == .u16be || self == .i16be || self == .u32be { ordered.reverse() }
        var value: UInt32 = 0
        for (i, b) in ordered.enumerated() { value |= UInt32(b) << (8 * UInt32(i)) }
        switch self {
        case .i8: return Int(Int8(truncatingIfNeeded: value))
        case .i16le, .i16be: return Int(Int16(truncatingIfNeeded: value))
        default: return Int(value)
        }
    }
}

/// Modelo de comando escrito como texto, por exemplo:
///
///     "FE DC BA C0 07 {len:u16be:1} {seq} {mode} EF"
///
/// Trechos aceitos:
/// - `AA`                  byte fixo em hexadecimal
/// - `{nome}` / `{nome:u16le}`  parâmetro inteiro (u8 por padrão) ou bloco de bytes
/// - `{seq}`               número de sequência de 1 byte (incrementa a cada comando)
/// - `{len:enc:N}`         tamanho dos bytes depois deste campo, menos os N últimos
/// - `{sum8}` `{xor8}` `{crc16le}` `{crc16be}` (opcional `:inicio`) checksum dos bytes anteriores
public struct CommandTemplate: Equatable, Sendable {
    public let source: String

    public init(_ source: String) { self.source = source }

    private enum Piece {
        case fixed([UInt8])
        case length(IntEncoding, tail: Int)
        case checksum(kind: String, start: Int)
    }

    public func build(_ params: [String: TemplateValue] = [:], sequence: UInt8 = 0) throws -> Data {
        var pieces: [Piece] = []
        for token in tokenize(source) {
            if token.hasPrefix("{") {
                guard token.hasSuffix("}") else { throw TemplateError.badToken(token) }
                let parts = token.dropFirst().dropLast().split(separator: ":").map(String.init)
                guard let name = parts.first, !name.isEmpty else { throw TemplateError.badToken(token) }
                switch name {
                case "seq":
                    pieces.append(.fixed([sequence]))
                case "len":
                    let enc = parts.count > 1 ? IntEncoding(rawValue: parts[1]) : .u8
                    guard let enc else { throw TemplateError.badToken(token) }
                    let tail = parts.count > 2 ? Int(parts[2]) ?? 0 : 0
                    pieces.append(.length(enc, tail: tail))
                case "sum8", "xor8", "crc16le", "crc16be":
                    let start = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
                    pieces.append(.checksum(kind: name, start: start))
                default:
                    guard let value = params[name] else { throw TemplateError.missingParameter(name) }
                    switch value {
                    case .bytes(let data):
                        pieces.append(.fixed(Array(data)))
                    case .int(let v):
                        let enc = parts.count > 1 ? IntEncoding(rawValue: parts[1]) : .u8
                        guard let enc else { throw TemplateError.badToken(token) }
                        pieces.append(.fixed(try enc.encode(v, name: name)))
                    }
                }
            } else {
                guard token.count == 2, let byte = UInt8(token, radix: 16) else {
                    throw TemplateError.badToken(token)
                }
                pieces.append(.fixed([byte]))
            }
        }

        // 1ª passada: posições e tamanhos de cada pedaço.
        func size(_ p: Piece) -> Int {
            switch p {
            case .fixed(let b): return b.count
            case .length(let enc, _): return enc.size
            case .checksum(let kind, _): return kind.hasPrefix("crc16") ? 2 : 1
            }
        }
        let total = pieces.reduce(0) { $0 + size($1) }
        var out = [UInt8](repeating: 0, count: total)
        var offsets: [Int] = []
        var cursor = 0
        for p in pieces {
            offsets.append(cursor)
            if case .fixed(let b) = p { out.replaceSubrange(cursor..<cursor + b.count, with: b) }
            cursor += size(p)
        }
        // 2ª passada: tamanhos.
        for (i, p) in pieces.enumerated() {
            if case .length(let enc, let tail) = p {
                let after = total - (offsets[i] + enc.size) - tail
                let bytes = try enc.encode(after, name: "len")
                out.replaceSubrange(offsets[i]..<offsets[i] + enc.size, with: bytes)
            }
        }
        // 3ª passada: checksums, na ordem em que aparecem.
        for (i, p) in pieces.enumerated() {
            if case .checksum(let kind, let start) = p {
                let range = out[min(start, offsets[i])..<offsets[i]]
                let bytes: [UInt8]
                switch kind {
                case "sum8": bytes = [Checksum.sum8(range)]
                case "xor8": bytes = [Checksum.xor8(range)]
                case "crc16le": bytes = try IntEncoding.u16le.encode(Int(Checksum.crc16CCITT(range)), name: kind)
                default: bytes = try IntEncoding.u16be.encode(Int(Checksum.crc16CCITT(range)), name: kind)
                }
                out.replaceSubrange(offsets[i]..<offsets[i] + bytes.count, with: bytes)
            }
        }
        return Data(out)
    }

    private func tokenize(_ s: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inBraces = false
        func flush() {
            if !current.isEmpty { tokens.append(current); current = "" }
        }
        for ch in s {
            if inBraces {
                current.append(ch)
                if ch == "}" { inBraces = false; flush() }
            } else if ch == "{" {
                flush(); inBraces = true; current.append(ch)
            } else if ch == " " || ch == "," || ch == "\n" || ch == "\t" {
                flush()
            } else {
                current.append(ch)
                // Sequências coladas como "AA01" viram bytes de 2 em 2.
                if current.count == 2, current.allSatisfy({ $0.isHexDigit }) { flush() }
            }
        }
        flush()
        return tokens
    }
}

/// Padrão de bytes para reconhecer notificações. `??` vale qualquer byte.
public struct BytePattern: Equatable, Sendable {
    public let bytes: [UInt8?]

    public init(_ text: String) throws {
        var result: [UInt8?] = []
        let compact = text.filter { !" :-,".contains($0) }
        var i = compact.startIndex
        while i < compact.endIndex {
            guard let j = compact.index(i, offsetBy: 2, limitedBy: compact.endIndex) else {
                throw HexError.oddLength
            }
            let pair = String(compact[i..<j])
            if pair == "??" { result.append(nil) }
            else if let b = UInt8(pair, radix: 16) { result.append(b) }
            else { throw HexError.invalidCharacter(pair) }
            i = j
        }
        bytes = result
    }

    public func matches(_ data: Data) -> Bool {
        guard data.count >= bytes.count else { return false }
        for (expected, actual) in zip(bytes, data) {
            if let expected, expected != actual { return false }
        }
        return true
    }
}
