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

#if os(iOS)
/// Keeps the native expanding drawer behavior while giving its disclosure indicator
/// a larger, explicit app-dominant tint.
struct LauncherDisclosureGroupStyle: DisclosureGroupStyle {
    let accentColor: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.22)) {
                configuration.isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                configuration.label
                Spacer(minLength: 6)
                Image(systemName: "chevron.down")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isEnabled ? accentColor : Color(white: 0.58))
                    .rotationEffect(.degrees(configuration.isExpanded ? 0 : -90))
                    .animation(.easeInOut(duration: 0.22), value: configuration.isExpanded)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .padding(.trailing, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        // Keep the expanded content as a separate List row. Wrapping both
        // header and content in a VStack makes the List resize one large row,
        // which can cause the abrupt jump during expansion and collapse.
        if configuration.isExpanded {
            configuration.content
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
#endif

struct SettingRow: View {
    let s: Setting
    @ObservedObject var m: LauncherModel
    let accentColor: Color
    @State private var showingChoiceList = false

    #if os(iOS)
    private var selectedChoiceLabel: String {
        let value = m.values[s.env] ?? s.def
        return s.options?.first(where: { $0.count >= 2 && $0[0] == value })?[1] ?? value
    }

    private var choiceListContent: some View {
        VStack(spacing: 0) {
            ForEach(s.options ?? [], id: \.self) { option in
                if option.count >= 2 {
                    Button {
                        m.values[s.env] = option[0]
                        withAnimation(.easeInOut(duration: 0.24)) {
                            showingChoiceList = false
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(option[1])
                                .foregroundStyle(locked ? Color(white: 0.58) : .white)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            if (m.values[s.env] ?? s.def) == option[0] {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color(red: 0.22, green: 0.48, blue: 0.28))
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Rectangle()
                        .fill(Color.white.opacity(0.12))
                        .frame(height: 0.5)
                }
            }
        }
        .padding(.top, 4)
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
                DisclosureGroup(isExpanded: $showingChoiceList) {
                    choiceListContent
                } label: {
                    HStack(spacing: 8) {
                        settingLabel
                        Spacer(minLength: 6)
                        Text(selectedChoiceLabel)
                            .foregroundStyle(locked ? Color(white: 0.58) : accentColor)
                            .lineLimit(1)
                    }
                }
                .disclosureGroupStyle(LauncherDisclosureGroupStyle(accentColor: accentColor))
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
