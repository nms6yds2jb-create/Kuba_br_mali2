import Foundation

/// Modos de controle de ruído do fone.
public enum NoiseMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case off
    case anc
    case transparency
    case wind

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .off: return "Desligado"
        case .anc: return "Cancelamento de ruído"
        case .transparency: return "Ambiente"
        case .wind: return "Redução de vento"
        }
    }
}

public enum EarSide: String, Codable, CaseIterable, Identifiable, Sendable {
    case left, right
    public var id: String { rawValue }
    public var title: String { self == .left ? "Esquerdo" : "Direito" }
}

public enum TouchGesture: String, Codable, CaseIterable, Identifiable, Sendable {
    case singleTap, doubleTap, tripleTap, longPress
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .singleTap: return "Toque simples"
        case .doubleTap: return "Toque duplo"
        case .tripleTap: return "Toque triplo"
        case .longPress: return "Toque longo"
        }
    }
}

public enum TouchAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, playPause, nextTrack, previousTrack, volumeUp, volumeDown
    case voiceAssistant, cycleNoiseMode, gameMode, answerCall
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .none: return "Nenhuma"
        case .playPause: return "Play / Pause"
        case .nextTrack: return "Próxima faixa"
        case .previousTrack: return "Faixa anterior"
        case .volumeUp: return "Volume +"
        case .volumeDown: return "Volume −"
        case .voiceAssistant: return "Siri"
        case .cycleNoiseMode: return "Alternar ANC / Ambiente"
        case .gameMode: return "Modo jogo"
        case .answerCall: return "Atender / desligar"
        }
    }
}

public struct TouchBinding: Codable, Hashable, Sendable {
    public var side: EarSide
    public var gesture: TouchGesture
    public var action: TouchAction

    public init(side: EarSide, gesture: TouchGesture, action: TouchAction) {
        self.side = side
        self.gesture = gesture
        self.action = action
    }
}

public struct BatteryStatus: Codable, Equatable, Sendable {
    public var left: Int?
    public var right: Int?
    public var caseLevel: Int?

    public init(left: Int? = nil, right: Int? = nil, caseLevel: Int? = nil) {
        self.left = left
        self.right = right
        self.caseLevel = caseLevel
    }

    /// Menor nível conhecido entre os dois fones (usado na trava de segurança do firmware).
    public var lowestEarbud: Int? {
        [left, right].compactMap { $0 }.min()
    }
}

/// Comando de alto nível que a interface pede; o driver traduz para bytes.
public enum HeadsetCommand: Equatable, Sendable {
    case setNoiseMode(NoiseMode)
    case setEqualizer([Double])
    case setTouch(TouchBinding)
    case setGameMode(Bool)
    case requestBattery
    case requestInfo
    case raw(Data)

    /// Nome usado como chave no perfil JSON.
    public var profileKey: String {
        switch self {
        case .setNoiseMode: return "noiseMode"
        case .setEqualizer: return "equalizer"
        case .setTouch: return "touch"
        case .setGameMode: return "gameMode"
        case .requestBattery: return "battery"
        case .requestInfo: return "info"
        case .raw: return "raw"
        }
    }
}

/// Evento decodificado de uma notificação do fone.
public enum HeadsetEvent: Equatable, Sendable {
    case battery(BatteryStatus)
    case noiseMode(NoiseMode)
    case firmwareVersion(String)
    case ack(String)
    case unknown(Data)
}
