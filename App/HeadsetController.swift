import Combine
import CoreBluetooth
import Foundation
import KubaCore

/// Liga a tela ao fone: escolhe o perfil, envia comandos e interpreta respostas.
final class HeadsetController: ObservableObject {
    enum Link: Equatable { case none, demo, bluetooth }

    @Published private(set) var link: Link = .none
    @Published private(set) var profile: CommandProfile?
    @Published var battery = BatteryStatus()
    @Published var genericBattery: Int?
    @Published var noiseMode: NoiseMode = .off
    @Published var equalizer = Equalizer()
    @Published var touchBindings: [TouchBinding] = HeadsetController.defaultTouch
    @Published var gameMode = false
    @Published var firmwareVersion: String?
    @Published var message: String?
    @Published var userPresets: [EQPreset] = []

    let bluetooth: BluetoothManager
    let profiles: ProfileStore
    private(set) var simulator: KubaOpenSimulator?
    private var driver: ProfileDriver?
    private var bag = Set<AnyCancellable>()
    private var pendingAck: (id: UUID, pattern: BytePattern, continuation: CheckedContinuation<Data?, Never>)?

    static let defaultTouch: [TouchBinding] = [
        TouchBinding(side: .left, gesture: .singleTap, action: .playPause),
        TouchBinding(side: .right, gesture: .singleTap, action: .playPause),
        TouchBinding(side: .left, gesture: .doubleTap, action: .previousTrack),
        TouchBinding(side: .right, gesture: .doubleTap, action: .nextTrack),
        TouchBinding(side: .left, gesture: .tripleTap, action: .volumeDown),
        TouchBinding(side: .right, gesture: .tripleTap, action: .volumeUp),
        TouchBinding(side: .left, gesture: .longPress, action: .cycleNoiseMode),
        TouchBinding(side: .right, gesture: .longPress, action: .voiceAssistant),
    ]

    init(bluetooth: BluetoothManager, profiles: ProfileStore) {
        self.bluetooth = bluetooth
        self.profiles = profiles
        userPresets = Self.loadPresets()
        bluetooth.onReady = { [weak self] in self?.bluetoothReady() }
        bluetooth.onValue = { [weak self] uuid, data in self?.bluetoothValue(uuid, data) }
        bluetooth.$connected
            .sink { [weak self] peripheral in
                guard let self, peripheral == nil, self.link == .bluetooth else { return }
                self.link = .none
            }
            .store(in: &bag)
        bluetooth.$standardBattery.assign(to: &$genericBattery)
    }

    // MARK: - Conexão

    var isConnected: Bool { link != .none }

    var deviceName: String {
        switch link {
        case .demo: return "Fone de demonstração"
        case .bluetooth: return bluetooth.connected?.name ?? "Fone"
        case .none: return "Nenhum fone"
        }
    }

    func startDemo() {
        bluetooth.disconnect()
        let sim = KubaOpenSimulator()
        simulator = sim
        link = .demo
        use(profiles.profile(id: "kubaopen"))
        refresh()
    }

    func disconnect() {
        if link == .bluetooth { bluetooth.disconnect() }
        link = .none
        simulator = nil
        firmwareVersion = nil
        battery = BatteryStatus()
    }

    /// Troca o perfil manualmente (tela Perfis).
    func use(_ newProfile: CommandProfile?) {
        guard let newProfile else {
            profile = nil
            driver = nil
            return
        }
        do {
            driver = try ProfileDriver(profile: newProfile)
            profile = newProfile
            equalizer = Self.loadEqualizer(for: newProfile)
            touchBindings = Self.loadTouch(for: newProfile)
            if link == .bluetooth { subscribeNotify() }
            message = newProfile.verified ? nil :
                "Perfil \"\(newProfile.name)\" não verificado: os comandos podem não funcionar."
        } catch {
            message = "Perfil inválido: \(error)"
        }
    }

    private func bluetoothReady() {
        link = .bluetooth
        simulator = nil
        let services = bluetooth.services.map(\.uuid)
        let chosen = profiles.bestMatch(name: bluetooth.connected?.name, services: services)
        use(chosen)
        if chosen == nil {
            message = "Nenhum perfil reconhece este fone ainda. Use o Explorador para descobrir os comandos."
        }
        refresh()
    }

    private func subscribeNotify() {
        guard let profile, bluetooth.hasCharacteristic(profile.transport.notify) else { return }
        bluetooth.setNotify(true, for: profile.transport.notify)
    }

    func refresh() {
        if supports(.requestInfo) { send(.requestInfo, quiet: true) }
        if supports(.requestBattery) { send(.requestBattery, quiet: true) }
    }

    // MARK: - Comandos

    func supports(_ command: HeadsetCommand) -> Bool { driver?.supports(command) ?? false }

    func send(_ command: HeadsetCommand, quiet: Bool = false) {
        guard let driver else {
            if !quiet { message = "Escolha um perfil antes de enviar comandos." }
            return
        }
        do {
            deliver(try driver.encode(command))
        } catch {
            if !quiet { message = "\(error)" }
        }
    }

    private func deliver(_ data: Data) {
        switch link {
        case .demo:
            bluetooth.addInfo("(demo) → \(data.hexString())")
            for reply in simulator?.receive(data) ?? [] {
                bluetooth.addInfo("(demo) ← \(reply.hexString())")
                handleIncoming(reply)
            }
        case .bluetooth:
            guard let profile else { return }
            bluetooth.write(data, to: profile.transport.write, withResponse: profile.transport.writeWithResponse)
        case .none:
            message = "Conecte um fone primeiro."
        }
    }

    private func bluetoothValue(_ uuid: String, _ data: Data) {
        guard let profile, BLEUUID.normalize(profile.transport.notify) == uuid else { return }
        handleIncoming(data)
    }

    private func handleIncoming(_ data: Data) {
        if let pending = pendingAck, pending.pattern.matches(data) {
            pendingAck = nil
            pending.continuation.resume(returning: data)
        }
        guard let event = driver?.decode(data) else { return }
        switch event {
        case .battery(let status): battery = status
        case .noiseMode(let mode): noiseMode = mode
        case .firmwareVersion(let v): firmwareVersion = v
        case .ack, .unknown: break
        }
    }

    func setNoiseMode(_ mode: NoiseMode) {
        noiseMode = mode
        send(.setNoiseMode(mode))
    }

    func setGameMode(_ on: Bool) {
        gameMode = on
        send(.setGameMode(on))
    }

    func applyEqualizer() {
        send(.setEqualizer(equalizer.gains))
        if let profile { Self.save(equalizer, key: "eq.\(profile.id)") }
    }

    func applyPreset(_ preset: EQPreset) {
        equalizer.apply(preset)
        applyEqualizer()
    }

    func saveCurrentAsPreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        userPresets.removeAll { $0.name == trimmed }
        userPresets.append(EQPreset(name: trimmed, gains: equalizer.gains))
        Self.save(userPresets, key: "eq.userPresets")
    }

    func deletePreset(_ preset: EQPreset) {
        userPresets.removeAll { $0 == preset }
        Self.save(userPresets, key: "eq.userPresets")
    }

    func action(for side: EarSide, _ gesture: TouchGesture) -> TouchAction {
        touchBindings.first { $0.side == side && $0.gesture == gesture }?.action ?? .none
    }

    func setAction(_ action: TouchAction, side: EarSide, gesture: TouchGesture) {
        let binding = TouchBinding(side: side, gesture: gesture, action: action)
        touchBindings.removeAll { $0.side == side && $0.gesture == gesture }
        touchBindings.append(binding)
        send(.setTouch(binding))
        if let profile { Self.save(touchBindings, key: "touch.\(profile.id)") }
    }

    func resetTouch() {
        for b in Self.defaultTouch { setAction(b.action, side: b.side, gesture: b.gesture) }
    }

    func sendRaw(_ data: Data) { deliver(data) }

    // MARK: - Firmware

    /// Bateria usada na trava de segurança do OTA.
    var batteryForUpdate: BatteryStatus? {
        if battery.lowestEarbud != nil { return battery }
        if let g = genericBattery { return BatteryStatus(left: g, right: g) }
        return nil
    }

    func makeOTATransport() -> OTATransport { ControllerOTATransport(controller: self) }

    /// Envia e espera a confirmação (chamado pelo transporte OTA, sempre na fila principal).
    fileprivate func sendAwaiting(_ data: Data, ack: BytePattern?, timeoutMs: Int,
                                  continuation: CheckedContinuation<Data?, Never>) {
        guard let ack else {
            deliver(data)
            continuation.resume(returning: Data())
            return
        }
        if let old = pendingAck { old.continuation.resume(returning: nil) }
        let id = UUID()
        pendingAck = (id, ack, continuation)
        deliver(data)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(timeoutMs)) { [weak self] in
            guard let self, let pending = self.pendingAck, pending.id == id else { return }
            self.pendingAck = nil
            pending.continuation.resume(returning: nil)
        }
    }

    // MARK: - Preferências salvas

    private static func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func loadEqualizer(for profile: CommandProfile) -> Equalizer {
        let base = profile.makeEqualizer()
        guard let saved = load(Equalizer.self, key: "eq.\(profile.id)"),
              saved.frequencies == base.frequencies else { return base }
        var eq = base
        for (i, g) in saved.gains.enumerated() { eq.setGain(g, at: i) }
        return eq
    }

    private static func loadTouch(for profile: CommandProfile) -> [TouchBinding] {
        load([TouchBinding].self, key: "touch.\(profile.id)") ?? defaultTouch
    }

    private static func loadPresets() -> [EQPreset] {
        load([EQPreset].self, key: "eq.userPresets") ?? []
    }
}

private final class ControllerOTATransport: OTATransport {
    weak var controller: HeadsetController?

    init(controller: HeadsetController) { self.controller = controller }

    func send(_ data: Data, expecting ack: BytePattern?, timeoutMs: Int) async throws -> Data? {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { [weak self] in
                guard let controller = self?.controller else {
                    continuation.resume(returning: nil)
                    return
                }
                controller.sendAwaiting(data, ack: ack, timeoutMs: timeoutMs, continuation: continuation)
            }
        }
    }
}
