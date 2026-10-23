import Foundation

/// Fone virtual que fala o protocolo KubaOpen. Usado no modo demonstração do app
/// e nos testes. É também a referência do lado do fone (o firmware em C faz o mesmo).
public final class KubaOpenSimulator {
    public private(set) var noiseMode: UInt8 = 0
    public private(set) var eqGains: [Int8] = Array(repeating: 0, count: 10)
    public private(set) var touch: [String: UInt8] = [:]
    public private(set) var gameMode = false
    public var battery: (left: UInt8, right: UInt8, caseLevel: UInt8) = (82, 79, 60)
    public var version: (UInt8, UInt8, UInt8) = (1, 0, 0)

    public private(set) var otaBuffer = Data()
    public private(set) var otaExpectedSize = 0
    public private(set) var otaExpectedCrc: UInt32 = 0
    public private(set) var installedFirmware: Data?
    /// Quantos pacotes de OTA ignorar (para testar novas tentativas).
    public var dropNextChunks = 0

    private var rx = Data()
    private var txSeq: UInt8 = 0

    public init() {}

    /// Entrega bytes vindos do celular (podem chegar picados). Retorna as respostas.
    public func receive(_ data: Data) -> [Data] {
        rx.append(data)
        var replies: [Data] = []
        while true {
            // Procura o cabeçalho 55 AA.
            guard let start = findHeader() else { rx.removeAll(); break }
            if start > 0 { rx.removeFirst(start) }
            guard rx.count >= 3 else { break }
            let len = Int(rx[rx.startIndex + 2])
            let total = 3 + len + 1
            guard rx.count >= total else { break }
            let frame = Array(rx.prefix(total))
            rx.removeFirst(total)
            guard Checksum.sum8(frame[2..<(total - 1)]) == frame[total - 1], len >= 2 else { continue }
            replies += handle(cmd: frame[4], payload: Array(frame[5..<(total - 1)]))
        }
        return replies
    }

    private func findHeader() -> Int? {
        let bytes = Array(rx)
        guard bytes.count >= 2 else { return bytes.first == 0x55 ? 0 : nil }
        for i in 0..<(bytes.count - 1) where bytes[i] == 0x55 && bytes[i + 1] == 0xAA { return i }
        return bytes.last == 0x55 ? bytes.count - 1 : nil
    }

    public func frame(_ cmd: UInt8, _ payload: [UInt8]) -> Data {
        var body: [UInt8] = [UInt8(payload.count + 2), txSeq, cmd] + payload
        txSeq &+= 1
        body.append(Checksum.sum8(body))
        return Data([0x55, 0xAA] + body)
    }

    private func ack(_ cmd: UInt8, ok: Bool = true) -> Data { frame(0x7F, [cmd, ok ? 0 : 1]) }

    private func handle(cmd: UInt8, payload p: [UInt8]) -> [Data] {
        switch cmd {
        case 0x01 where p.count >= 1:
            noiseMode = p[0]
            return [ack(cmd), frame(0x81, [noiseMode])]
        case 0x02 where p.count >= 1:
            let count = Int(p[0])
            guard p.count >= 1 + count else { return [ack(cmd, ok: false)] }
            eqGains = p[1..<(1 + count)].map { Int8(bitPattern: $0) }
            return [ack(cmd)]
        case 0x03 where p.count >= 3:
            touch["\(p[0])-\(p[1])"] = p[2]
            return [ack(cmd)]
        case 0x04 where p.count >= 1:
            gameMode = p[0] != 0
            return [ack(cmd)]
        case 0x05:
            return [frame(0x85, [battery.left, battery.right, battery.caseLevel])]
        case 0x06:
            return [frame(0x86, [version.0, version.1, version.2]), frame(0x81, [noiseMode])]
        case 0x10 where p.count >= 10:
            otaExpectedSize = Int(IntEncoding.u32le.decode(p[0..<4]) ?? 0)
            otaExpectedCrc = UInt32(IntEncoding.u32le.decode(p[4..<8]) ?? 0)
            otaBuffer = Data()
            return [ack(cmd)]
        case 0x11 where p.count >= 4:
            if dropNextChunks > 0 { dropNextChunks -= 1; return [] }
            let offset = IntEncoding.u32le.decode(p[0..<4]) ?? -1
            // Bloco repetido (reenvio) é aceito sem duplicar dados.
            if offset + (p.count - 4) <= otaBuffer.count { return [ack(cmd)] }
            guard offset == otaBuffer.count else { return [ack(cmd, ok: false)] }
            otaBuffer.append(contentsOf: p[4...])
            return [ack(cmd)]
        case 0x12 where p.count >= 4:
            let ok = otaBuffer.count == otaExpectedSize && Checksum.crc32(otaBuffer) == otaExpectedCrc
            if ok {
                installedFirmware = otaBuffer
                version = (version.0, version.1, version.2 &+ 1)
            }
            return ok ? [ack(cmd)] : [frame(0x7E, [cmd, 1])]
        default:
            return [ack(cmd, ok: false)]
        }
    }
}

/// Transporte OTA ligado direto no simulador (sem Bluetooth).
public final class SimulatorTransport: OTATransport {
    public let simulator: KubaOpenSimulator
    public private(set) var sentFrames: [Data] = []

    public init(simulator: KubaOpenSimulator) { self.simulator = simulator }

    public func send(_ data: Data, expecting ack: BytePattern?, timeoutMs: Int) async throws -> Data? {
        sentFrames.append(data)
        let replies = simulator.receive(data)
        guard let ack else { return replies.first ?? Data() }
        return replies.first(where: { ack.matches($0) })
    }
}
