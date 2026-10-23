import KubaCore
import SwiftUI
import UniformTypeIdentifiers

struct FirmwareView: View {
    @EnvironmentObject var controller: HeadsetController
    @EnvironmentObject var bluetooth: BluetoothManager

    @State private var image: FirmwareImage?
    @State private var picking = false
    @State private var simulateOnly = true
    @State private var acceptedRisk = false
    @State private var confirm = false
    @State private var engine: OTAEngine?
    @State private var progress: OTAProgress?
    @State private var result: String?
    @State private var running = false

    private var ota: CommandProfile.OTASpec? { controller.profile?.ota }

    var body: some View {
        NavigationStack {
            List {
                Section("Fone") {
                    LabeledContent("Versão atual", value: controller.firmwareVersion
                                   ?? bluetooth.deviceInfo["Firmware"] ?? "desconhecida")
                    if let maker = bluetooth.deviceInfo["Fabricante"] {
                        LabeledContent("Fabricante", value: maker)
                    }
                    if let model = bluetooth.deviceInfo["Modelo"] {
                        LabeledContent("Modelo", value: model)
                    }
                    LabeledContent("Atualização pelo app", value: ota == nil ? "não disponível" : "disponível")
                }

                if ota == nil {
                    Section {
                        Text("O perfil atual não sabe como enviar firmware. Isso depende do chip do fone. Veja o guia docs/FIRMWARE.md no projeto: ele explica como identificar o chip, fazer backup e, se quiser, gravar um firmware próprio pelos contatos de carga/USB.")
                            .font(.footnote)
                    }
                }

                Section("Arquivo") {
                    Button { picking = true } label: {
                        Label(image == nil ? "Escolher arquivo de firmware…" : "Trocar arquivo…",
                              systemImage: "doc.badge.arrow.up")
                    }
                    if let image {
                        LabeledContent("Nome", value: image.fileName)
                        LabeledContent("Tamanho", value: ByteCountFormatter.string(fromByteCount: Int64(image.size), countStyle: .file))
                        LabeledContent("CRC32", value: String(format: "%08X", image.crc32))
                        LabeledContent("Tipo provável", value: image.vendorHint)
                        Text(image.headerHex).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        ForEach(image.problems, id: \.self) { Label($0, systemImage: "xmark.octagon").foregroundStyle(.red) }
                    }
                }

                if let image, let ota {
                    Section {
                        Toggle("Apenas simular (não envia nada)", isOn: $simulateOnly)
                        if !simulateOnly {
                            Toggle("Entendo que um firmware errado pode inutilizar o fone e que a garantia é perdida.",
                                   isOn: $acceptedRisk)
                                .font(.footnote)
                        }
                        Button(simulateOnly ? "Simular envio" : "Atualizar firmware") {
                            if simulateOnly { simulate(image, ota) } else { confirm = true }
                        }
                        .disabled(running || !image.problems.isEmpty || (!simulateOnly && !acceptedRisk))
                    } header: {
                        Text("Envio")
                    } footer: {
                        Text("Antes de começar: os dois fones fora do estojo, bateria acima de \(ota.minBattery)%, celular perto e sem outros apps de Bluetooth abertos. Não feche o app durante o envio.")
                    }
                }

                if let progress {
                    Section("Progresso") {
                        ProgressView(value: progress.fraction) {
                            Text(progress.stage)
                        } currentValueLabel: {
                            Text("\(progress.sentBytes) de \(progress.totalBytes) bytes")
                        }
                        if running {
                            Button("Cancelar", role: .destructive) { engine?.cancel() }
                        }
                    }
                }

                if let result {
                    Section("Resultado") { Text(result).font(.footnote) }
                }
            }
            .navigationTitle("Firmware")
            .fileImporter(isPresented: $picking, allowedContentTypes: [.data]) { pick($0) }
            .confirmationDialog("Gravar firmware agora?", isPresented: $confirm, titleVisibility: .visible) {
                Button("Gravar", role: .destructive) { if let image, let ota { run(image, ota) } }
            } message: {
                Text("Não desligue o fone nem saia do app até terminar.")
            }
        }
    }

    private func pick(_ selection: Result<URL, Error>) {
        result = nil
        progress = nil
        switch selection {
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                image = FirmwareImage(data: try Data(contentsOf: url), fileName: url.lastPathComponent)
            } catch {
                result = "Não foi possível ler o arquivo: \(error.localizedDescription)"
            }
        case .failure(let error):
            result = error.localizedDescription
        }
    }

    private func simulate(_ image: FirmwareImage, _ ota: CommandProfile.OTASpec) {
        let engine = OTAEngine(spec: ota, image: image)
        do {
            let frames = try engine.frames()
            let biggest = frames.map(\.count).max() ?? 0
            let mtu = bluetooth.maxWriteLength(for: controller.profile?.transport.write ?? "",
                                               withResponse: controller.profile?.transport.writeWithResponse ?? false)
            var text = "Simulação ok: \(frames.count) pacotes (\(engine.chunkCount) blocos de até \(ota.chunkSize) bytes). Maior pacote: \(biggest) bytes."
            if controller.link == .bluetooth && biggest > mtu {
                text += " Atenção: o Bluetooth aceita \(mtu) bytes por escrita; os pacotes serão divididos."
            }
            do { try engine.preflight(battery: controller.batteryForUpdate) } catch {
                text += "\nTrava de segurança: \(error)"
            }
            if let first = frames.first { text += "\nPrimeiro pacote: \(first.hexString())" }
            result = text
        } catch {
            result = "Erro ao montar os pacotes: \(error)"
        }
    }

    private func run(_ image: FirmwareImage, _ ota: CommandProfile.OTASpec) {
        let engine = OTAEngine(spec: ota, image: image)
        self.engine = engine
        running = true
        result = nil
        let transport = controller.makeOTATransport()
        let battery = controller.batteryForUpdate
        Task { @MainActor in
            do {
                try await engine.run(battery: battery, via: transport) { p in
                    DispatchQueue.main.async { progress = p }
                }
                result = "Firmware enviado. O fone deve reiniciar sozinho; depois reconecte."
                controller.refresh()
            } catch {
                result = "\(error)"
            }
            running = false
        }
    }
}
