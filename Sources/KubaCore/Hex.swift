import Foundation

public enum HexError: Error, Equatable {
    case invalidCharacter(String)
    case oddLength
}

public extension Data {
    /// "AA 01 ff" -> bytes. Aceita espaços, ":" e "-" como separadores e prefixo 0x.
    init(hex: String) throws {
        var cleaned = hex.replacingOccurrences(of: "0x", with: "")
            .replacingOccurrences(of: "0X", with: "")
        cleaned.removeAll { " :-,\n\t".contains($0) }
        guard cleaned.count % 2 == 0 else { throw HexError.oddLength }
        var bytes = [UInt8]()
        bytes.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            let pair = String(cleaned[index..<next])
            guard let byte = UInt8(pair, radix: 16) else { throw HexError.invalidCharacter(pair) }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }

    /// bytes -> "AA 01 FF"
    func hexString(separator: String = " ") -> String {
        map { String(format: "%02X", $0) }.joined(separator: separator)
    }
}
