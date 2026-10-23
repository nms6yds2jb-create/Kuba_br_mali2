import KubaCore
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var controller: HeadsetController
    @EnvironmentObject var bluetooth: BluetoothManager

    var body: some View {
        NavigationStack {
            List {
                if let message = controller.message {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .onTapGesture { controller.message = nil }
                    }
                }
                if controller.isConnected {
                    ConnectedSection()
                    NoiseSection()
                } else {
                    ScanSection()
                }
            }
            .navigationTitle("Kuba Control")
            .refreshable { controller.refresh() }
        }
    }
}

private struct ConnectedSection: View {
    @EnvironmentObject var controller: HeadsetController
    @EnvironmentObject var bluetooth: BluetoothManager

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(controller.deviceName).font(.title2.bold())
                Text("Perfil: \(controller.profile?.name ?? "nenhum")")
                    .font(.footnote).foregroundStyle(.secondary)
                if let v = controller.firmwareVersion ?? bluetooth.deviceInfo["Firmware"] {
                    Text("Firmware \(v)").font(.footnote).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 12) {
                BatteryTile(title: "Esquerdo", level: controller.battery.left ?? controller.genericBattery)
                BatteryTile(title: "Direito", level: controller.battery.right ?? controller.genericBattery)
                BatteryTile(title: "Estojo", level: controller.battery.caseLevel)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            Button("Desconectar", role: .destructive) { controller.disconnect() }
        }
    }
}

private struct BatteryTile: View {
    let title: String
    let level: Int?

    var symbol: String {
        guard let level else { return "battery.0" }
        switch level {
        case ..<15: return "battery.0"
        case ..<40: return "battery.25"
        case ..<65: return "battery.50"
        case ..<90: return "battery.75"
        default: return "battery.100"
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.title2)
                .foregroundStyle((level ?? 100) < 20 ? Color.red : Color.primary)
            Text(level.map { "\($0)%" } ?? "—").font(.headline.monospacedDigit())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct NoiseSection: View {
    @EnvironmentObject var controller: HeadsetController

    var body: some View {
        Section {
            let enabled = controller.supports(.setNoiseMode(.anc))
            HStack(spacing: 10) {
                ForEach(NoiseMode.allCases) { mode in
                    NoiseButton(mode: mode, selected: controller.noiseMode == mode) {
                        controller.setNoiseMode(mode)
                    }
                }
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.4)
            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            Toggle("Modo jogo (baixa latência)", isOn: Binding(
                get: { controller.gameMode },
                set: { controller.setGameMode($0) }))
                .disabled(!controller.supports(.setGameMode(true)))
        } header: {
            Text("Controle de ruído")
        } footer: {
            if !controller.supports(.setNoiseMode(.anc)) {
                Text("O perfil atual ainda não tem o comando de ANC. Veja Avançado › Explorador.")
            }
        }
    }
}

private struct NoiseButton: View {
    let mode: NoiseMode
    let selected: Bool
    let action: () -> Void

    var icon: String {
        switch mode {
        case .off: return "speaker.wave.1"
        case .anc: return "ear.trianglebadge.exclamationmark"
        case .transparency: return "ear"
        case .wind: return "wind"
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title3)
                Text(mode.title).font(.caption2).multilineTextAlignment(.center).lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(selected ? Color.orange.opacity(0.25) : Color.secondary.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.orange : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }
}

private struct ScanSection: View {
    @EnvironmentObject var controller: HeadsetController
    @EnvironmentObject var bluetooth: BluetoothManager

    var body: some View {
        Section {
            Button {
                if bluetooth.isScanning { bluetooth.stopScan() } else { bluetooth.startScan() }
            } label: {
                Label(bluetooth.isScanning ? "Parar busca" : "Procurar fones",
                      systemImage: bluetooth.isScanning ? "stop.circle" : "magnifyingglass")
            }
            .disabled(!bluetooth.isPoweredOn)
            Button { controller.startDemo() } label: {
                Label("Usar fone de demonstração", systemImage: "play.circle")
            }
        } header: {
            Text(bluetooth.connectionState)
        } footer: {
            Text("Dica: deixe o Mali 2 fora do estojo. Se ele já estiver conectado ao iPhone, aparece no topo como \"conectado\".")
        }

        if !bluetooth.devices.isEmpty {
            Section("Aparelhos encontrados") {
                ForEach(bluetooth.devices) { device in
                    Button { bluetooth.connect(device) } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(device.name).foregroundStyle(.primary)
                                Text(device.alreadyConnected ? "conectado ao iPhone" : "sinal \(device.rssi) dBm")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if looksLikeKuba(device.name) {
                                Text("Kuba?").font(.caption.bold()).foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }
        }
    }

    private func looksLikeKuba(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("kuba") || lower.contains("mali")
    }
}
