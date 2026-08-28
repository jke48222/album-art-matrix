// Settings. A place you visit, not a place you live: the wall's address,
// the sleep fade, the panel check, and the accessible copy of the brightness
// control that lives on the panel everywhere else.

import SwiftUI

struct SettingsSheet: View {
    @Environment(WallSession.self) private var wall
    @Environment(\.dismiss) private var dismiss

    let accent: Color

    @State private var host: String = ""
    @State private var sleepMinutes: Double = 30
    @State private var brightness: Double = 1

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 34) {
                    HStack(spacing: 10) {
                        TesseraMark(accent: accent, lit: 0.8, side: 16)
                        Text("SETUP")
                            .font(.display(17))
                            .kerning(2.8)
                            .foregroundStyle(Ink.ink)
                    }
                    .padding(.bottom, -8)

                    theWall
                    sleep
                    light
                    panelCheck
                    about
                }
                .padding(20)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .background(Ink.ground.ignoresSafeArea())
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.ui(15, .medium))
                        .foregroundStyle(accent)
                }
            }
        }
        .presentationBackground(Ink.ground)
        .preferredColorScheme(.dark)
        .onAppear {
            host = wall.host
            brightness = wall.state.brightness
        }
    }

    // MARK: - Sections

    private var theWall: some View {
        Section("the wall", note: "Where Tessera looks for it. The wall answers on port 8788.") {
            TextField("album-matrix.local:8788", text: $host)
                .font(.machine(13))
                .foregroundStyle(Ink.ink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
                .background(Ink.sunk)
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Ink.hairline, lineWidth: 1) }
                .onSubmit { commitHost() }

            HStack(spacing: 10) {
                Button("Use this address") { commitHost() }
                    .buttonStyle(.plain)
                    .font(.ui(13, .medium))
                    .foregroundStyle(accent)
                Spacer()
                LinkChip(link: wall.link)
            }
            .padding(.top, 10)
        }
    }

    private var sleep: some View {
        Section("sleep", note: "Fade the wall down over time, then let it go dark. Zero cancels a fade in progress.") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(sleepMinutes < 1 ? "off" : "\(Int(sleepMinutes))")
                    .font(.machine(26))
                    .foregroundStyle(sleepMinutes < 1 ? Ink.faint : accent)
                    .contentTransition(.numericText())
                if sleepMinutes >= 1 {
                    Text("min").font(.machine(10)).foregroundStyle(Ink.faint)
                }
            }
            Slider(value: $sleepMinutes, in: 0...120, step: 5)
                .tint(accent)
                .padding(.top, 4)
            HStack(spacing: 10) {
                Button("Start the fade") {
                    Taps.commit()
                    wall.send(["sleep_fade_min": sleepMinutes])
                }
                .buttonStyle(.plain)
                .font(.ui(13, .medium))
                .foregroundStyle(sleepMinutes < 1 ? Ink.faint : accent)
                .disabled(sleepMinutes < 1)

                if let left = wall.state.sleepRemaining, left > 0 {
                    Spacer()
                    Text("\(left / 60)m \(left % 60)s left")
                        .font(.machine(10))
                        .foregroundStyle(Ink.dim)
                }
            }
            .padding(.top, 8)
        }
    }

    private var light: some View {
        Section("light", note: "The same control that lives on the panel. It is here so it is reachable without a drag.") {
            HStack {
                Text("\(Int(brightness * 100))%")
                    .font(.machine(15))
                    .foregroundStyle(Ink.ink)
                Spacer()
            }
            Slider(value: $brightness, in: 0.05...1.0, step: 0.05) { editing in
                if !editing { wall.send(["brightness": brightness]) }
            }
            .tint(accent)
        }
    }

    private var panelCheck: some View {
        Section("panel check", note: "Puts a flat field on the wall so a dead emitter or a colour cast has nowhere to hide. The wall keeps showing it until you pick a mode again.") {
            let patterns: [(String, (UInt8, UInt8, UInt8))] = [
                ("white", (255, 255, 255)),
                ("red", (255, 0, 0)),
                ("green", (0, 255, 0)),
                ("blue", (0, 0, 255)),
            ]
            HStack(spacing: 10) {
                ForEach(patterns, id: \.0) { (name, rgb) in
                    Button {
                        Taps.commit()
                        wall.pushFlat(r: rgb.0, g: rgb.1, b: rgb.2)
                    } label: {
                        VStack(spacing: 8) {
                            Circle()
                                .fill(Color(red: Double(rgb.0) / 255,
                                            green: Double(rgb.1) / 255,
                                            blue: Double(rgb.2) / 255))
                                .frame(height: 44)
                                .overlay { Circle().strokeBorder(Ink.hairline, lineWidth: 1) }
                            Text(name)
                                .font(.machine(9))
                                .textCase(.uppercase)
                                .foregroundStyle(Ink.faint)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show full \(name) on the wall")
                }
            }
            Button("Back to the album") {
                Taps.commit()
                wall.send(["mode": "art"])
            }
            .buttonStyle(.plain)
            .font(.ui(13, .medium))
            .foregroundStyle(accent)
            .padding(.top, 14)
        }
    }

    private var about: some View {
        Section("about", note: nil) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Tessera")
                    .font(.display(17))
                    .kerning(1.4)
                    .foregroundStyle(Ink.ink)
                Text("A remote for a wall of 4,096 emitters. Nothing leaves your network: the app talks to the wall directly and keeps no account.")
                    .font(.ui(13))
                    .foregroundStyle(Ink.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func commitHost() {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        wall.host = trimmed
        Taps.commit()
        Task { await wall.pollState() }
    }
}

/// A settings block: label, controls, and one honest sentence about what the
/// thing does. Not a card, not a grouped list row.
private struct Section<Content: View>: View {
    let label: String
    let note: String?
    @ViewBuilder let content: Content

    init(_ label: String, note: String?, @ViewBuilder content: () -> Content) {
        self.label = label
        self.note = note
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(label)
                .font(.machine(10))
                .textCase(.uppercase)
                .kerning(0.8)
                .foregroundStyle(Ink.faint)
            content
            if let note {
                Text(note)
                    .font(.ui(12))
                    .foregroundStyle(Ink.faint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
