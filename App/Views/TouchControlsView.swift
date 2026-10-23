import KubaCore
import SwiftUI

struct TouchControlsView: View {
    @EnvironmentObject var controller: HeadsetController

    private var supported: Bool {
        controller.supports(.setTouch(TouchBinding(side: .left, gesture: .singleTap, action: .none)))
    }

    var body: some View {
        NavigationStack {
            List {
                if !supported {
                    Section {
                        Label("O perfil atual ainda não tem o comando de toques. As escolhas ficam salvas e são enviadas quando o perfil for completado.",
                              systemImage: "info.circle")
                            .font(.footnote)
                    }
                }
                ForEach(EarSide.allCases) { side in
                    Section("Fone \(side.title.lowercased())") {
                        ForEach(TouchGesture.allCases) { gesture in
                            Picker(gesture.title, selection: Binding(
                                get: { controller.action(for: side, gesture) },
                                set: { controller.setAction($0, side: side, gesture: gesture) })) {
                                ForEach(availableActions) { action in
                                    Text(action.title).tag(action)
                                }
                            }
                        }
                    }
                }
                Section {
                    Button("Restaurar padrão") { controller.resetTouch() }
                }
            }
            .navigationTitle("Toques")
        }
    }

    /// Mostra só as ações que o perfil sabe codificar (ou todas, se o perfil não diz).
    private var availableActions: [TouchAction] {
        guard let map = controller.profile?.touchActions, !map.isEmpty else { return TouchAction.allCases }
        return TouchAction.allCases.filter { map[$0.rawValue] != nil }
    }
}
