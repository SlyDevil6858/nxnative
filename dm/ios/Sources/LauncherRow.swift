// One launcher setting as a row (a menu, a slider with its percentage, a toggle), shared by the iOS launcher (Launcher.swift) and the Mac app's settings window (dm/mac/Launcher.swift).
// A row whose setting is fixed by an env file or by the launch environment is shown but disabled.
import SwiftUI
#if os(iOS)
import UIKit
#endif

extension LauncherModel {
    func binding(_ s: Setting) -> Binding<String> { Binding(get: { self.values[s.env] ?? s.def }, set: { self.values[s.env] = $0 }) }
}

/// Keeps locked switches visibly subdued instead of using SwiftUI's brighter default disabled track.
private struct LauncherToggleStyle: ToggleStyle {
    let accentColor: Color
    let isLocked: Bool
    let label: String


    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer()
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isLocked ? Color(white: 0.16) : (configuration.isOn ? accentColor : Color(white: 0.14)))
                    .frame(width: 67, height: 31)
                Capsule()
                    .fill(isLocked ? Color(white: 0.48) : Color.white)
                    .frame(width: 42, height: 27)
            }
            .contentShape(Capsule())
            .onTapGesture {
                guard !isLocked else { return }
                #if os(iOS)
                let feedback = UIImpactFeedbackGenerator(style: .light)
                feedback.prepare()
                feedback.impactOccurred()
                #endif
                configuration.isOn.toggle()
            }
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(configuration.isOn ? "On" : "Off")
            .accessibilityHint(isLocked ? "This setting is fixed by the launch environment." : "Double-tap to change.")
        }
    }
}

struct SettingRow: View {
    let s: Setting
    @ObservedObject var m: LauncherModel
    let accentColor: Color
    @State private var showingChoicePopover = false

    #if os(iOS)
    private var selectedChoiceLabel: String {
        let value = m.values[s.env] ?? s.def
        return s.options?.first(where: { $0.count >= 2 && $0[0] == value })?[1] ?? value
    }

    private var choicePopover: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(s.options ?? [], id: \.self) { option in
                    if option.count >= 2 {
                        Button {
                            m.values[s.env] = option[0]
                            showingChoicePopover = false
                        } label: {
                            HStack(spacing: 8) {
                                Text(option[1]).lineLimit(1)
                                Spacer(minLength: 4)
                                if (m.values[s.env] ?? s.def) == option[0] {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.white)
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(height: 40)
                        Rectangle()
                            .fill(Color.white.opacity(0.12))
                            .frame(height: 0.5)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .frame(width: 288)
        .frame(maxHeight: 240)
        .padding(8)
        .background(Color(red: 0.035, green: 0.035, blue: 0.035).opacity(0.98))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Color.white.opacity(0.16), lineWidth: 1))
        .presentationBackground(Color(red: 0.035, green: 0.035, blue: 0.035).opacity(0.98))
        .presentationCornerRadius(10)
        .presentationCompactAdaptation(.popover)
        .environment(\.colorScheme, .dark)
    }
    #endif

    private var locked: Bool { m.fixed.contains(s.env) }
    private var note: String {
        guard locked else { return s.note }
        return (s.note.isEmpty ? "" : s.note + " · ") + (m.fromLaunch.contains(s.env) ? "Set at launch" : "Set by an env file")
    }
    private var rangeValue: Binding<Double> {
        Binding(get: { Double(m.values[s.env] ?? s.def) ?? s.max ?? 1 },
                set: { m.values[s.env] = String(format: "%.2f", $0) })
    }
    private var percentage: String { m.rangeLabel(s, rangeValue.wrappedValue) }

    private var settingLabel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(s.label)
            if !note.isEmpty { Text(note).font(.footnote).foregroundStyle(Color(white: 0.58)) }
        }
    }

    var body: some View {
        Group {
            switch s.kind {
            case "choice":
                #if os(iOS)
                Button {
                    showingChoicePopover = true
                } label: {
                    HStack(spacing: 8) {
                        settingLabel
                        Spacer(minLength: 8)
                        Text(selectedChoiceLabel)
                            .foregroundStyle(accentColor)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(accentColor)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showingChoicePopover, arrowEdge: .trailing) {
                    choicePopover
                }
                #else
                Picker(selection: m.binding(s)) {
                    ForEach(s.options ?? [], id: \.self) { Text($0[1]).tag($0[0]) }
                } label: {
                    settingLabel
                }
                .pickerStyle(.menu)
                .tint(accentColor)
                #endif
            case "range":
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        settingLabel
                        Spacer()
                        Text(percentage).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: rangeValue, in: (s.min ?? 0)...(s.max ?? 1), step: s.step ?? 0.05)
                        .tint(accentColor)
                        .accessibilityLabel(s.label)
                        .accessibilityValue(percentage)
                }
            default:
                Toggle(isOn: Binding(get: { (m.values[s.env] ?? s.def) == s.onValue }, set: { m.values[s.env] = $0 ? s.onValue : s.offValue })) {
                    settingLabel
                }
                .toggleStyle(LauncherToggleStyle(accentColor: accentColor, isLocked: locked, label: s.label))
            }
        }
        .disabled(locked)
    }
}
