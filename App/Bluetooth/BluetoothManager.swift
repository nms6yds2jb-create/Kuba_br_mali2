import CoreBluetooth
import Foundation
import KubaCore

struct DiscoveredDevice: Identifiable, Equatable {
    let id: UUID
    var name: String
    var rssi: Int
    var advertisedServices: [String]
    var alreadyConnected: Bool
    let peripheral: CBPeripheral
}

struct CharacteristicInfo: Identifiable, Equatable {
    var id: String { serviceUUID + "/" + uuid }
    let uuid: String
    let serviceUUID: String
    let properties: CBCharacteristicProperties
    var isNotifying: Bool
    var lastValue: Data?

    var propertyNames: [String] {
        var names: [String] = []
        if properties.contains(.read) { names.append("ler") }
        if properties.contains(.write) { names.append("escrever") }
        if properties.contains(.writeWithoutResponse) { names.append("escrever s/ resp.") }
        if properties.contains(.notify) { names.append("notificar") }
        if properties.contains(.indicate) { names.append("indicar") }
        return names
    }
}

struct ServiceInfo: Identifiable, Equatable {
    var id: String { uuid }
    let uuid: String
    var characteristics: [CharacteristicInfo]
    var hint: String? { VendorHints.label(for: uuid) }
}

struct LogEntry: Identifiable {
    enum Direction: String { case sent = "→", received = "←", info = "•" }
    let id = UUID()
    let date = Date()
    let direction: Direction
    let characteristic: String
    let data: Data?
    let text: String?

    var line: String {
        let time = LogEntry.formatter.string(from: date)
        if let data { return "\(time) \(direction.rawValue) [\(characteristic)] \(data.hexString())" }
        return "\(time) \(direction.rawValue) \(text ?? "")"
    }

    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

/// Pistas sobre o fabricante do chip a partir dos serviços BLE encontrados.
enum VendorHints {
    static let known: [String: String] = [
        "AE00": "Possível chip JieLi (serviço RCSP)",
        "5052494D-2DAB-0341-6972-6F6861424C45": "Possível chip Airoha (serviço RACE)",
        "FE2C": "Google Fast Pair",
        "180F": "Bateria (padrão Bluetooth)",
        "180A": "Informações do aparelho (padrão Bluetooth)",
        "1812": "HID (controle remoto / teclado)",
        "FFF0": "Serviço genérico de fabricante (comum em chips chineses)",
        "FF00": "Serviço genérico de fabricante",
        "6B756261-4F50-454E-0000-000000000001": "KubaOpen (firmware próprio)",
    ]

    static func label(for uuid: String) -> String? { known[BLEUUID.normalize(uuid)] }

    /// Serviços usados para achar o fone mesmo quando ele já está conectado ao iPhone
    /// (fones conectados normalmente param de anunciar).
    static var retrieveServices: [CBUUID] {
        known.keys.map { CBUUID(string: $0) }
    }
}

/// Camada CoreBluetooth: busca, conexão, descoberta de serviços, leitura, escrita e registro.
final class BluetoothManager: NSObject, ObservableObject {
    @Published private(set) var isPoweredOn = false
    @Published private(set) var isScanning = false
    @Published private(set) var devices: [DiscoveredDevice] = []
    @Published private(set) var connected: CBPeripheral?
    @Published private(set) var connectionState = "Desconectado"
    @Published private(set) var services: [ServiceInfo] = []
    @Published private(set) var log: [LogEntry] = []
    @Published private(set) var deviceInfo: [String: String] = [:]
    @Published private(set) var standardBattery: Int?

    /// Chamado a cada notificação/leitura recebida.
    var onValue: ((String, Data) -> Void)?
    /// Chamado quando os serviços terminam de ser descobertos.
    var onReady: (() -> Void)?

    private var central: CBCentralManager!
    private var characteristics: [String: CBCharacteristic] = [:]
    private var pendingServiceDiscovery = 0

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - Busca e conexão

    func startScan() {
        guard isPoweredOn else { return }
        devices.removeAll()
        for p in central.retrieveConnectedPeripherals(withServices: VendorHints.retrieveServices) {
            upsert(p, name: p.name, rssi: 0, services: [], alreadyConnected: true)
        }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        isScanning = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.stopScan() }
    }

    func stopScan() {
        central.stopScan()
        isScanning = false
    }

    func connect(_ device: DiscoveredDevice) {
        stopScan()
        if let current = connected { central.cancelPeripheralConnection(current) }
        connectionState = "Conectando a \(device.name)…"
        addInfo("Conectando a \(device.name) (\(device.id.uuidString))")
        device.peripheral.delegate = self
        central.connect(device.peripheral)
    }

    func disconnect() {
        if let p = connected { central.cancelPeripheralConnection(p) }
    }

    private func upsert(_ p: CBPeripheral, name: String?, rssi: Int, services: [String], alreadyConnected: Bool) {
        let display = name ?? p.name ?? "Sem nome"
        if let i = devices.firstIndex(where: { $0.id == p.identifier }) {
            devices[i].rssi = rssi
            if name != nil { devices[i].name = display }
            if !services.isEmpty { devices[i].advertisedServices = services }
        } else {
            devices.append(DiscoveredDevice(id: p.identifier, name: display, rssi: rssi,
                                            advertisedServices: services, alreadyConnected: alreadyConnected,
                                            peripheral: p))
        }
        devices.sort { a, b in
            if a.alreadyConnected != b.alreadyConnected { return a.alreadyConnected }
            let aNamed = a.name != "Sem nome", bNamed = b.name != "Sem nome"
            if aNamed != bNamed { return aNamed }
            return a.rssi > b.rssi
        }
    }

    // MARK: - Leitura / escrita

    private func key(_ uuid: String) -> String { BLEUUID.normalize(uuid) }

    func hasCharacteristic(_ uuid: String) -> Bool { characteristics[key(uuid)] != nil }

    func maxWriteLength(for uuid: String, withResponse: Bool) -> Int {
        guard let p = connected else { return 20 }
        return p.maximumWriteValueLength(for: withResponse ? .withResponse : .withoutResponse)
    }

    /// Escreve em uma característica. Pacotes maiores que o MTU são divididos.
    @discardableResult
    func write(_ data: Data, to uuid: String, withResponse: Bool) -> Bool {
        guard let p = connected, let c = characteristics[key(uuid)] else {
            addInfo("Característica \(uuid) não encontrada neste aparelho.")
            return false
        }
        let type: CBCharacteristicWriteType
        if withResponse && c.properties.contains(.write) { type = .withResponse }
        else if c.properties.contains(.writeWithoutResponse) { type = .withoutResponse }
        else { type = .withResponse }
        let chunk = Swift.max(p.maximumWriteValueLength(for: type), 20)
        var offset = 0
        while offset < data.count {
            let piece = data.subdata(in: offset..<Swift.min(offset + chunk, data.count))
            p.writeValue(piece, for: c, type: type)
            offset += chunk
        }
        log.append(LogEntry(direction: .sent, characteristic: key(uuid), data: data, text: nil))
        return true
    }

    func read(_ uuid: String) {
        guard let p = connected, let c = characteristics[key(uuid)] else { return }
        p.readValue(for: c)
    }

    func setNotify(_ on: Bool, for uuid: String) {
        guard let p = connected, let c = characteristics[key(uuid)] else { return }
        p.setNotifyValue(on, for: c)
    }

    func clearLog() { log.removeAll() }

    func addInfo(_ text: String) {
        log.append(LogEntry(direction: .info, characteristic: "", data: nil, text: text))
        if log.count > 2000 { log.removeFirst(log.count - 2000) }
    }

    var logText: String { log.map(\.line).joined(separator: "\n") }

    private func updateCharacteristic(_ c: CBCharacteristic) {
        guard let s = c.service else { return }
        let sKey = key(s.uuid.uuidString), cKey = key(c.uuid.uuidString)
        guard let si = services.firstIndex(where: { $0.uuid == sKey }),
              let ci = services[si].characteristics.firstIndex(where: { $0.uuid == cKey }) else { return }
        services[si].characteristics[ci].isNotifying = c.isNotifying
        services[si].characteristics[ci].lastValue = c.value
    }
}

extension BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        isPoweredOn = central.state == .poweredOn
        switch central.state {
        case .poweredOn: connectionState = connected == nil ? "Desconectado" : connectionState
        case .unauthorized: connectionState = "Permita o Bluetooth em Ajustes > Kuba Control"
        case .poweredOff: connectionState = "Bluetooth desligado"
        default: connectionState = "Bluetooth indisponível"
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        let uuids = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []).map(\.uuidString)
        upsert(peripheral, name: name, rssi: RSSI.intValue, services: uuids, alreadyConnected: false)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connected = peripheral
        connectionState = "Conectado a \(peripheral.name ?? "aparelho")"
        services = []
        characteristics = [:]
        deviceInfo = [:]
        standardBattery = nil
        addInfo("Conectado. Descobrindo serviços…")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectionState = "Falha ao conectar"
        addInfo("Falha ao conectar: \(error?.localizedDescription ?? "erro desconhecido")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if connected?.identifier == peripheral.identifier {
            connected = nil
            services = []
            characteristics = [:]
        }
        connectionState = "Desconectado"
        let reason = error.map { ": " + $0.localizedDescription } ?? ""
        addInfo("Desconectado" + reason)
    }
}

extension BluetoothManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let list = peripheral.services ?? []
        pendingServiceDiscovery = list.count
        for s in list {
            services.append(ServiceInfo(uuid: key(s.uuid.uuidString), characteristics: []))
            let hint = VendorHints.label(for: s.uuid.uuidString).map { " — " + $0 } ?? ""
            addInfo("Serviço " + s.uuid.uuidString + hint)
            peripheral.discoverCharacteristics(nil, for: s)
        }
        if list.isEmpty { onReady?() }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let sKey = key(service.uuid.uuidString)
        for c in service.characteristics ?? [] {
            let cKey = key(c.uuid.uuidString)
            characteristics[cKey] = c
            let info = CharacteristicInfo(uuid: cKey, serviceUUID: sKey, properties: c.properties,
                                          isNotifying: c.isNotifying, lastValue: nil)
            if let i = services.firstIndex(where: { $0.uuid == sKey }) { services[i].characteristics.append(info) }
            // Lê sozinho as informações padrão (fabricante, modelo, firmware) e a bateria.
            if sKey == "180A" || cKey == "2A19", c.properties.contains(.read) { peripheral.readValue(for: c) }
            if cKey == "2A19", c.properties.contains(.notify) { peripheral.setNotifyValue(true, for: c) }
        }
        pendingServiceDiscovery -= 1
        if pendingServiceDiscovery <= 0 {
            addInfo("Descoberta concluída.")
            onReady?()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value else { return }
        let cKey = key(characteristic.uuid.uuidString)
        updateCharacteristic(characteristic)
        log.append(LogEntry(direction: .received, characteristic: cKey, data: value, text: nil))
        if let label = DeviceInfoKeys.label[cKey] {
            deviceInfo[label] = String(decoding: value, as: UTF8.self).trimmingCharacters(in: .controlCharacters)
        }
        if cKey == "2A19", let level = value.first { standardBattery = Int(level) }
        onValue?(cKey, value)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        updateCharacteristic(characteristic)
        if let error { addInfo("Erro ao ativar notificações: \(error.localizedDescription)") }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { addInfo("Erro na escrita: \(error.localizedDescription)") }
    }
}

enum DeviceInfoKeys {
    static let label: [String: String] = [
        "2A29": "Fabricante",
        "2A24": "Modelo",
        "2A25": "Número de série",
        "2A26": "Firmware",
        "2A27": "Hardware",
        "2A28": "Software",
    ]
}
