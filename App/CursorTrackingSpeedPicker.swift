import SwiftUI

struct CursorTrackingSpeedPicker: View {
    @Binding var selection: Double?

    private var choices: [Double] {
        let steps = CursorTrackingSpeed.choices
        guard let selection, !steps.contains(selection) else { return steps }
        return (steps + [selection]).sorted()
    }

    var body: some View {
        Picker("光标跟踪速度", selection: $selection) {
            Text("跟随应用设置").tag(nil as Double?)
            ForEach(choices, id: \.self) { speed in
                Text(verbatim: speed.formatted(.number.precision(.fractionLength(0...3))) + "×")
                    .tag(speed as Double?)
            }
        }
        .pickerStyle(.menu)
    }
}
