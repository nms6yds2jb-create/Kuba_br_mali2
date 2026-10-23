import CoreBluetooth
import KubaCore
import SwiftUI
import UniformTypeIdentifiers

struct AdvancedView: View {
    @EnvironmentObject var bluetooth: BluetoothManager

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { ExplorerView() } label: {
                        Label("Explorador Bluetooth", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    NavigationLink { ProfilesView() } label: {
                        Label("Perfis de protocolo", systemImage: "doc.text")
                    }
                    NavigationLink { LogView() } label: {
                        Label("Registro de pacotes (\(bluetooth.log.count))", systemImage: "list.bullet.rectangle")
                    }
                } footer: {
                    Text("Ferramentas para descobrir os comandos do Mali 2 e ensinar o app a controlá-lo.")
                }
                Section("Como descobrir o protocolo") {
                    Text("1. Conecte o fone pela aba Fone.\n2. Abra o Explorador e veja os serviços. Os marcados com pista de fabricante são os mais promissores.\n3. Ative \"notificar\" nas características que permitem e observe o registro enquanto troca o modo pelo toque no fone.\n4. Crie um perfil com esses dados e teste comandos.\nO passo a passo completo está em docs/DESCOBRIR_PROTOCOLO.md.")
                        .font(.footnote)
                }
            }
            .navigationTitle("Avançado")
        }
    }
}

// MARK: - Explorador

struct ExplorerView: View {
    @EnvironmentObject var bluetooth: BluetoothManager

    var body: some View {
        List {
            if bluetooth.connected == nil {
                Text("Conecte um aparelho pela aba Fone para ver os serviços.").foregroundStyle(.secondary)
            }
            if !bluetooth.deviceInfo.isEmpty {
                Section("Informações do aparelho") {
                    ForEach(bluetooth.deviceInfo.sorted(by: { $0.key < $1.key }), id: \.key) { item in
                        LabeledContent(item.key, value: item.value)
                    }
                }
            }
            ForEach(bluetooth.services) { service in
                Section {
                    ForEach(service.characteristics) { c in
                        NavigationLink { CharacteristicView(characteristicID: c.id) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.uuid).font(.caption.monospaced())
                                Text(c.propertyNames.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
                                if let v = c.lastValue {
                                    Text(v.hexString()).font(.caption2.monospaced()).lineLimit(1)
                                }
                            }
                        }
                    }
                } header: {
                    VStack(alignment: .leading) {
                        Text(service.uuid).font(.caption.monospaced())
                        if let hint = service.hint { Text(hint).foregroundStyle(.orange) }
                    }
                }
            }
        }
        .navigationTitle("Explorador")
    }
}

struct CharacteristicView: View {
    @EnvironmentObject var bluetooth: BluetoothManager
    let characteristicID: String
    @State private var hex = ""
    @State private var withResponse = false
    @State private var error: String?

    private var info: CharacteristicInfo? {
        bluetooth.services.flatMap(\.characteristics).first { $0.id == characteristicID }
    }

    var body: some View {
        List {
            if let c = info {
                Section("Característica") {
                    LabeledContent("UUID", value: c.uuid)
                    LabeledContent("Serviço", value: c.serviceUUID)
                    LabeledContent("Permite", value: c.propertyNames.joined(separator: ", "))
                }
                Section("Último valor") {
                    if let v = c.lastValue {
                        Text(v.hexString()).font(.caption.monospaced()).textSelection(.enabled)
                        Text(String(decoding: v, as: UTF8.self)).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("nenhum").foregroundStyle(.secondary)
                    }
                    if c.properties.contains(.read) { Button("Ler agora") { bluetooth.read(c.uuid) } }
                    if c.properties.contains(.notify) || c.properties.contains(.indicate) {
                        Toggle("Receber notificações", isOn: Binding(
                            get: { c.isNotifying },
                            set: { bluetooth.setNotify($0, for: c.uuid) }))
                    }
                }
                if c.properties.contains(.write) || c.properties.contains(.writeWithoutResponse) {
                    Section {
                        TextField("Bytes em hex, ex.: AA 01 02", text: $hex)
                            .font(.body.monospaced())
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                        if c.properties.contains(.write) && c.properties.contains(.writeWithoutResponse) {
                            Toggle("Com confirmação", isOn: $withResponse)
                        }
                        Button("Enviar") { send(c) }
                        if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                    } header: {
                        Text("Enviar")
                    } footer: {
                        Text("Cuidado: bytes aleatórios podem disparar modos de fábrica. Teste um comando de cada vez e anote o que acontece.")
                    }
                }
            }
        }
        .navigationTitle("Característica")
    }

    private func send(_ c: CharacteristicInfo) {
        do {
            let data = try Data(hex: hex)
            error = nil
            bluetooth.write(data, to: c.uuid, withResponse: withResponse || !c.properties.contains(.writeWithoutResponse))
        } catch {
            self.error = "Hex inválido."
        }
    }
}

// MARK: - Registro

struct LogView: View {
    @EnvironmentObject var bluetooth: BluetoothManager

    var body: some View {
        List(bluetooth.log.reversed()) { entry in
            Text(entry.line)
                .font(.caption2.monospaced())
                .foregroundStyle(entry.direction == .received ? Color.green
                                 : entry.direction == .sent ? Color.orange : Color.secondary)
                .textSelection(.enabled)
        }
        .navigationTitle("Registro")
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                ShareLink(item: bluetooth.logText)
                Button("Limpar") { bluetooth.clearLog() }
            }
        }
    }
}

// MARK: - Perfis

struct ProfilesView: View {
    @EnvironmentObject var profiles: ProfileStore
    @EnvironmentObject var controller: HeadsetController
    @EnvironmentObject var bluetooth: BluetoothManager
    @State private var importing = false
    @State private var editing: ProfileDraft?
    @State private var error: String?

    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            ForEach(profiles.loadErrors, id: \.self) { Text($0).foregroundStyle(.red).font(.caption) }
            Section("Perfis") {
                ForEach(profiles.all, id: \.id) { profile in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(profile.name)
                            Text("\(profile.verified ? "verificado" : "não verificado") · \(profile.commands.count) comandos\(profiles.isUserProfile(profile.id) ? " · seu" : "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if controller.profile?.id == profile.id { Image(systemName: "checkmark").foregroundStyle(.orange) }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { controller.use(profile) }
                    .swipeActions {
                        Button("Editar") { editing = ProfileDraft(profile: profile) }.tint(.blue)
                        if profiles.isUserProfile(profile.id) {
                            Button("Apagar", role: .destructive) { profiles.delete(id: profile.id) }
                        }
                    }
                }
            }
            Section {
                Button("Novo perfil a partir do fone conectado") { editing = ProfileDraft(profile: draftFromConnected()) }
                    .disabled(bluetooth.connected == nil)
                Button("Importar arquivo JSON…") { importing = true }
            } footer: {
                Text("Deslize um perfil para editar. Perfis embutidos editados são salvos como cópia sua.")
            }
        }
        .navigationTitle("Perfis")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do { controller.use(try profiles.importFile(result.get())) } catch { self.error = "\(error)" }
        }
        .sheet(item: $editing) { draft in ProfileEditor(draft: draft) }
    }

    /// Monta um perfil inicial com o nome do fone e o primeiro serviço que tem escrita + notificação.
    private func draftFromConnected() -> CommandProfile {
        let name = bluetooth.connected?.name ?? "Meu fone"
        let candidate = bluetooth.services.first { s in
            s.uuid.count > 4 || !["1800", "1801", "180A", "180F"].contains(s.uuid)
        }
        let write = candidate?.characteristics.first {
            $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse)
        }
        let notify = candidate?.characteristics.first {
            $0.properties.contains(.notify) || $0.properties.contains(.indicate)
        }
        return CommandProfile(
            id: "meu-" + name.lowercased().filter { $0.isLetter || $0.isNumber },
            name: name, verified: false,
            notes: "Criado no app. Preencha os comandos.",
            match: .init(namePrefixes: [name]),
            transport: .init(service: candidate?.uuid ?? "FFFF", write: write?.uuid ?? "FFFF",
                             notify: notify?.uuid ?? "FFFF"),
            equalizer: .init(),
            noiseModes: ["off": 0, "anc": 1, "transparency": 2],
            commands: [:], events: [])
    }
}

struct ProfileDraft: Identifiable {
    let id = UUID()
    var profile: CommandProfile
}

struct ProfileEditor: View {
    @EnvironmentObject var profiles: ProfileStore
    @EnvironmentObject var controller: HeadsetController
    @Environment(\.dismiss) private var dismiss
    let draft: ProfileDraft
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading) {
                if let error { Text(error).foregroundStyle(.red).font(.footnote).padding(.horizontal) }
                TextEditor(text: $text)
                    .font(.caption.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            .navigationTitle(draft.profile.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fechar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Salvar") { save() } }
                ToolbarItem(placement: .bottomBar) { ShareLink(item: text) }
            }
            .onAppear {
                text = (try? draft.profile.encoded()).map { String(decoding: $0, as: UTF8.self) } ?? ""
            }
        }
    }

    private func save() {
        do {
            let profile = try CommandProfile.load(from: Data(text.utf8))
            try profiles.save(profile)
            controller.use(profile)
            dismiss()
        } catch {
            self.error = "Não salvou: \(error)"
        }
    }
}
