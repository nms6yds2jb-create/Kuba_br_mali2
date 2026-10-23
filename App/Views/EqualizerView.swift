import KubaCore
import SwiftUI

struct EqualizerView: View {
    @EnvironmentObject var controller: HeadsetController
    @State private var showSave = false
    @State private var presetName = ""

    private var supported: Bool { controller.supports(.setEqualizer([])) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    EQCurve(equalizer: controller.equalizer)
                        .frame(height: 140)
                        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                }
                Section("Predefinições") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(Equalizer.builtInPresets + controller.userPresets) { preset in
                                Button(preset.name) { controller.applyPreset(preset) }
                                    .buttonStyle(.bordered)
                                    .contextMenu {
                                        if controller.userPresets.contains(preset) {
                                            Button("Apagar", role: .destructive) { controller.deletePreset(preset) }
                                        }
                                    }
                            }
                        }
                    }
                }
                Section {
                    ForEach(controller.equalizer.frequencies.indices, id: \.self) { band in
                        BandRow(band: band)
                    }
                } header: {
                    Text("Bandas (\(Self.format(controller.equalizer.minGain)) a +\(Self.format(controller.equalizer.maxGain)) dB)")
                } footer: {
                    if !supported {
                        Text("O perfil atual não tem o comando de equalizador: os ajustes ficam salvos no app, mas não chegam ao fone. Complete o perfil em Avançado › Perfis.")
                    } else {
                        Text("O ajuste é enviado ao fone quando você solta o controle e fica gravado nele, valendo para qualquer app.")
                    }
                }
                Section {
                    Button("Salvar como predefinição…") { presetName = ""; showSave = true }
                    Button("Zerar tudo", role: .destructive) {
                        controller.applyPreset(Equalizer.builtInPresets[0])
                    }
                }
            }
            .navigationTitle("Equalizador")
            .alert("Nova predefinição", isPresented: $showSave) {
                TextField("Nome", text: $presetName)
                Button("Salvar") { controller.saveCurrentAsPreset(named: presetName) }
                Button("Cancelar", role: .cancel) {}
            }
        }
    }

    static func format(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
}

private struct BandRow: View {
    @EnvironmentObject var controller: HeadsetController
    let band: Int

    var body: some View {
        let eq = controller.equalizer
        HStack {
            Text(label(eq.frequencies[band]))
                .font(.caption.monospacedDigit())
                .frame(width: 44, alignment: .leading)
            Slider(value: Binding(
                get: { controller.equalizer.gains[band] },
                set: { controller.equalizer.setGain($0, at: band) }),
                in: eq.minGain...eq.maxGain, step: eq.step,
                onEditingChanged: { editing in
                    if !editing { controller.applyEqualizer() }
                })
            Text((eq.gains[band] > 0 ? "+" : "") + EqualizerView.format(eq.gains[band]))
                .font(.caption.monospacedDigit())
                .frame(width: 40, alignment: .trailing)
        }
    }

    private func label(_ f: Double) -> String {
        f >= 1000 ? "\(EqualizerView.format(f / 1000))k" : "\(Int(f))"
    }
}

/// Desenho da curva de resposta resultante.
struct EQCurve: View {
    let equalizer: Equalizer

    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            let range = max(equalizer.maxGain, 1)
            let lo = log10(20.0), hi = log10(20_000.0)
            let x: (Double) -> CGFloat = { f in CGFloat((log10(f) - lo) / (hi - lo)) * w }
            let y: (Double) -> CGFloat = { db in
                h / 2 - CGFloat(max(min(db, range), -range) / range) * (h / 2 - 4)
            }

            var zero = Path()
            zero.move(to: CGPoint(x: 0, y: h / 2))
            zero.addLine(to: CGPoint(x: w, y: h / 2))
            context.stroke(zero, with: .color(.secondary.opacity(0.5)),
                           style: StrokeStyle(lineWidth: 1, dash: [4]))

            var curve = Path()
            for (i, pt) in equalizer.curve(points: 120).enumerated() {
                let point = CGPoint(x: x(pt.frequency), y: y(pt.db))
                if i == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
            }
            context.stroke(curve, with: .color(.orange), style: StrokeStyle(lineWidth: 2.5, lineJoin: .round))

            for (f, g) in zip(equalizer.frequencies, equalizer.gains) {
                let rect = CGRect(x: x(f) - 3, y: y(g) - 3, width: 6, height: 6)
                context.fill(Path(ellipseIn: rect), with: .color(.orange))
            }
        }
        .accessibilityLabel("Curva do equalizador")
    }
}
