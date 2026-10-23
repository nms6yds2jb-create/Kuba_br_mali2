import Foundation

/// Arquivo de firmware carregado pelo usuário, com verificações básicas.
public struct FirmwareImage: Equatable, Sendable {
    public static let maxSize = 16 * 1024 * 1024

    public let data: Data
    public let fileName: String

    public init(data: Data, fileName: String) {
        self.data = data
        self.fileName = fileName
    }

    public var size: Int { data.count }
    public var crc32: UInt32 { Checksum.crc32(data) }
    public var headerHex: String { data.prefix(32).hexString() }

    /// Problemas que impedem o envio. Lista vazia = pode seguir.
    public var problems: [String] {
        var list: [String] = []
        if data.isEmpty { list.append("Arquivo vazio.") }
        if data.count > FirmwareImage.maxSize { list.append("Arquivo maior que 16 MB; não parece firmware de fone.") }
        if !data.isEmpty && data.allSatisfy({ $0 == 0xFF }) { list.append("Arquivo só tem 0xFF (flash apagada).") }
        if !data.isEmpty && data.allSatisfy({ $0 == 0x00 }) { list.append("Arquivo só tem zeros.") }
        return list
    }

    /// Palpite do formato pelo começo do arquivo. Só um indício, não uma garantia.
    public var vendorHint: String {
        let head = Array(data.prefix(256))
        if head.starts(with: [0x7F, 0x45, 0x4C, 0x46]) { return "Arquivo ELF (precisa virar binário antes)" }
        let text = String(decoding: head, as: UTF8.self).lowercased()
        for (needle, label) in [("jieli", "Possível JieLi"), ("bluetrum", "Possível Bluetrum"),
                                ("airoha", "Possível Airoha"), ("bestechnic", "Possível BES")]
            where text.contains(needle) {
            return label
        }
        return "Desconhecido"
    }
}

/// Canal usado pelo OTA. O app implementa com CoreBluetooth; os testes com um simulador.
public protocol OTATransport: AnyObject {
    /// Envia `data` e espera uma notificação que case com `ack`. Retorna a notificação.
    func send(_ data: Data, expecting ack: BytePattern?, timeoutMs: Int) async throws -> Data?
}

public enum OTAError: Error, Equatable, CustomStringConvertible {
    case notSupported
    case invalidImage([String])
    case batteryTooLow(Int, required: Int)
    case batteryUnknown
    case noAck(step: String)
    case cancelled

    public var description: String {
        switch self {
        case .notSupported: return "Este perfil não tem rotina de atualização (OTA)."
        case .invalidImage(let p): return "Firmware inválido: " + p.joined(separator: " ")
        case .batteryTooLow(let b, let r): return "Bateria em \(b)%. Carregue até pelo menos \(r)% antes de atualizar."
        case .batteryUnknown: return "Não foi possível ler a bateria. Por segurança a atualização foi bloqueada."
        case .noAck(let step): return "O fone não confirmou a etapa: \(step)."
        case .cancelled: return "Atualização cancelada."
        }
    }
}

public struct OTAProgress: Equatable, Sendable {
    public var sentBytes: Int
    public var totalBytes: Int
    public var stage: String
    public var fraction: Double { totalBytes == 0 ? 0 : Double(sentBytes) / Double(totalBytes) }
}

/// Fluxo genérico: start -> blocos (cada um com confirmação) -> finish.
public final class OTAEngine {
    public let spec: CommandProfile.OTASpec
    public let image: FirmwareImage
    private var cancelled = false

    public init(spec: CommandProfile.OTASpec, image: FirmwareImage) {
        self.spec = spec
        self.image = image
    }

    public func cancel() { cancelled = true }

    public var chunkCount: Int {
        let size = max(spec.chunkSize, 1)
        return (image.size + size - 1) / size
    }

    /// Checagens antes de mexer no fone.
    public func preflight(battery: BatteryStatus?) throws {
        let problems = image.problems
        guard problems.isEmpty else { throw OTAError.invalidImage(problems) }
        guard let level = battery?.lowestEarbud else { throw OTAError.batteryUnknown }
        guard level >= spec.minBattery else { throw OTAError.batteryTooLow(level, required: spec.minBattery) }
    }

    private var baseParams: [String: TemplateValue] {
        ["size": .int(image.size),
         "crc32": .int(Int(image.crc32)),
         "chunkSize": .int(spec.chunkSize),
         "chunks": .int(chunkCount)]
    }

    /// Todos os pacotes que seriam enviados, sem enviar nada (modo simulação).
    public func frames() throws -> [Data] {
        var list = [try CommandTemplate(spec.start).build(baseParams)]
        for index in 0..<chunkCount {
            list.append(try chunkFrame(index))
        }
        list.append(try CommandTemplate(spec.finish).build(baseParams))
        return list
    }

    private func chunkFrame(_ index: Int) throws -> Data {
        let offset = index * spec.chunkSize
        let end = min(offset + spec.chunkSize, image.size)
        let piece = image.data.subdata(in: offset..<end)
        var params = baseParams
        params["offset"] = .int(offset)
        params["index"] = .int(index)
        params["data"] = .bytes(piece)
        params["chunkCrc"] = .int(Int(Checksum.crc16CCITT(piece)))
        return try CommandTemplate(spec.chunk).build(params, sequence: UInt8(truncatingIfNeeded: index))
    }

    private func sendWithRetry(_ frame: Data, step: String, via transport: OTATransport) async throws {
        let ack = try BytePattern(spec.ackMatch)
        for _ in 0...max(spec.retries, 0) {
            if cancelled { throw OTAError.cancelled }
            if try await transport.send(frame, expecting: ack, timeoutMs: spec.ackTimeoutMs) != nil { return }
        }
        throw OTAError.noAck(step: step)
    }

    public func run(battery: BatteryStatus?, via transport: OTATransport,
                    progress: @escaping (OTAProgress) -> Void) async throws {
        try preflight(battery: battery)
        cancelled = false
        let total = image.size
        progress(OTAProgress(sentBytes: 0, totalBytes: total, stage: "Iniciando"))
        try await sendWithRetry(try CommandTemplate(spec.start).build(baseParams), step: "início", via: transport)
        for index in 0..<chunkCount {
            try await sendWithRetry(try chunkFrame(index), step: "bloco \(index + 1)/\(chunkCount)", via: transport)
            let sent = min((index + 1) * spec.chunkSize, total)
            progress(OTAProgress(sentBytes: sent, totalBytes: total, stage: "Enviando"))
        }
        try await sendWithRetry(try CommandTemplate(spec.finish).build(baseParams), step: "finalização", via: transport)
        progress(OTAProgress(sentBytes: total, totalBytes: total, stage: "Concluído"))
    }
}
