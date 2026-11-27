import SwiftUI

struct LibraryConnectionItem<Label: View>: View {
    let id: String
    @Binding var selection: String?
    let cornerRadius: CGFloat
    let connect: () -> Void
    let label: Label

    init(id: String, selection: Binding<String?>, cornerRadius: CGFloat = 8,
         connect: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.id = id
        _selection = selection
        self.cornerRadius = cornerRadius
        self.connect = connect
        self.label = label()
    }

    var body: some View {
        Button(action: connect) { label }
            #if targetEnvironment(macCatalyst)
            .buttonStyle(ConnectionSelectionStyle(selected: selection == id, cornerRadius: cornerRadius) {
                selection = id
            })
            #endif
            .accessibilityIdentifier(id)
    }
}

#if targetEnvironment(macCatalyst)
private struct ConnectionSelectionStyle: PrimitiveButtonStyle {
    let selected: Bool
    let cornerRadius: CGFloat
    let select: () -> Void

    func makeBody(configuration: Configuration) -> some View {
        ConnectionSelectionControl(label: configuration.label, selected: selected, cornerRadius: cornerRadius,
                                   select: select, connect: configuration.trigger)
    }
}

private struct ConnectionSelectionControl<Label: View>: View {
    let label: Label
    let selected: Bool
    let cornerRadius: CGFloat
    let select: () -> Void
    let connect: () -> Void
    @FocusState private var focused: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        label
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(shape)
            .overlay {
                if selected {
                    shape.fill(Color.accentColor.opacity(0.10))
                        .overlay {
                            shape.strokeBorder(Color.accentColor, lineWidth: contrast == .increased ? 2 : 1)
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .focusable()
            .focused($focused)
            .onChange(of: focused) { _, focused in if focused { select() } }
            .onTapGesture(count: 2) {
                select()
                connect()
            }
            .simultaneousGesture(TapGesture().onEnded {
                select()
                focused = true
            })
            .onKeyPress(keys: [.return, .space], phases: .down) { _ in
                connect()
                return .handled
            }
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityAction {
                select()
                connect()
            }
    }
}
#endif
