//
//  ContentView.swift
//  SunBeam
//

import SwiftUI

struct ContentView: View {
    @Environment(RazerController.self) private var controller

    // Persisted so the window reopens showing the last-staged values. Edits are
    // staged only — nothing is sent to the mouse until Apply is pressed. The
    // mouse itself remembers the actual lighting (VARSTORE), so we never re-send
    // on launch.
    @AppStorage("mode") private var modeRaw = RazerMode.staticColor.rawValue
    @AppStorage("colorHex") private var colorHex = "FF0000"
    @AppStorage("brightness") private var brightness = 1.0

    // Editable text mirror of `colorHex`; synced both ways with the color wheel.
    @State private var colorText = ""

    private var mode: RazerMode { RazerMode(rawValue: modeRaw) ?? .staticColor }

    private var colorBinding: Binding<Color> {
        Binding(get: { Color(hex: colorHex) }, set: { colorHex = $0.hexString })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            statusRow

            Divider()

            Picker("Effect", selection: $modeRaw) {
                ForEach(RazerMode.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 8) {
                ColorPicker("Color", selection: colorBinding, supportsOpacity: false)
                    .labelsHidden()
                TextField("Hex or R,G,B", text: $colorText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                    .onSubmit { commitColorText() }
            }
            .disabled(!mode.usesColor)
            .opacity(mode.usesColor ? 1 : 0.4)

            VStack(alignment: .leading, spacing: 6) {
                Text("Brightness").font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Image(systemName: "sun.min")
                    Slider(value: $brightness, in: 0...1)
                    Image(systemName: "sun.max.fill")
                }
                .foregroundStyle(.secondary)
                .disabled(mode == .off)
                .opacity(mode == .off ? 0.4 : 1)
            }

            if let error = controller.lastError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                batteryView
                Spacer()
                Button("Apply") { applyCurrent() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!controller.isConnected)
            }
        }
        // Title bar is hidden (see SunBeamApp), so the traffic-light buttons float
        // over the content — the extra top inset keeps the status row clear of them.
        .padding(EdgeInsets(top: 30, leading: 24, bottom: 24, trailing: 24))
        .frame(width: 340)
        .onAppear { colorText = "#" + colorHex }
        .onChange(of: colorHex) { colorText = "#" + colorHex }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(controller.isConnected ? Color.green : Color.secondary)
                .frame(width: 10, height: 10)
            Text(controller.statusText)
                .font(.headline)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// Battery indicator, shown only once the mouse has actually reported a
    /// level. Until then this row looks exactly the way it always has.
    @ViewBuilder
    private var batteryView: some View {
        if let percent = controller.batteryPercent {
            HStack(spacing: 5) {
                Image(systemName: batterySymbol(percent: percent))
                    .imageScale(.large)
                    .foregroundStyle(batteryColor(percent: percent))
                Text("\(percent)%")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .help(controller.isCharging ? "Mouse battery — charging" : "Mouse battery")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(controller.isCharging
                                ? "Mouse battery \(percent) percent, charging"
                                : "Mouse battery \(percent) percent")
        }
    }

    /// Only the glyph carries the level color — the percentage next to it stays
    /// secondary gray. Charging doesn't change the color, so a mouse charging at
    /// 8% still reads red.
    private func batteryColor(percent: Int) -> Color {
        switch percent {
        case 60...: return .green
        case 25...: return .yellow
        default: return .red
        }
    }

    /// Charging always gets the bolt glyph — the exact level is in the text
    /// right beside it, so one charging symbol covers every level.
    private func batterySymbol(percent: Int) -> String {
        guard !controller.isCharging else { return "battery.100percent.bolt" }
        switch percent {
        case 88...: return "battery.100percent"
        case 63...: return "battery.75percent"
        case 38...: return "battery.50percent"
        case 13...: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    private func applyCurrent() {
        let (r, g, b) = Color(hex: colorHex).rgbBytes
        controller.apply(mode: mode, r: r, g: g, b: b,
                         brightness: UInt8((brightness * 255).rounded()))
    }

    /// Parse whatever the user typed into the color field. On success stage the
    /// canonical hex (which refreshes the wheel and the field); on failure
    /// discard the bad input by reverting to the current color.
    private func commitColorText() {
        if let hex = Color.hex(fromUserInput: colorText) {
            colorHex = hex
            colorText = "#" + hex
        } else {
            colorText = "#" + colorHex
        }
    }
}

// MARK: - Color <-> bytes / hex helpers

extension Color {
    /// sRGB components as 0...255 bytes, matching what the mouse expects.
    var rgbBytes: (UInt8, UInt8, UInt8) {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .black
        func byte(_ v: CGFloat) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        return (byte(ns.redComponent), byte(ns.greenComponent), byte(ns.blueComponent))
    }

    var hexString: String {
        let (r, g, b) = rgbBytes
        return String(format: "%02X%02X%02X", r, g, b)
    }

    init(hex: String) {
        var string = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if string.hasPrefix("#") { string.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: string).scanHexInt64(&value)
        self = Color(.sRGB,
                     red: Double((value >> 16) & 0xFF) / 255,
                     green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }

    /// Parse a user-typed color as either hex (`#FF0000`, `FF0000`, shorthand
    /// `F00`) or an RGB triple (`255,0,0`, `255 0 0`, `rgb(255, 0, 0)`).
    /// Returns the canonical 6-digit uppercase hex, or nil if unrecognized.
    static func hex(fromUserInput input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("rgb") { s.removeFirst(3) }
        s = s.replacingOccurrences(of: "(", with: " ")
             .replacingOccurrences(of: ")", with: " ")

        // RGB triple: three integers separated by commas or whitespace.
        let parts = s.split { $0 == "," || $0 == " " }.map(String.init)
        if parts.count == 3, parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) {
            let values = parts.compactMap { Int($0) }
            guard values.count == 3, values.allSatisfy({ (0...255).contains($0) }) else { return nil }
            return String(format: "%02X%02X%02X", values[0], values[1], values[2])
        }

        // Hex: contiguous hex digits, optional leading '#', 3 or 6 long.
        var hex = s.hasPrefix("#") ? String(s.dropFirst()) : s
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, hex.allSatisfy(\.isHexDigit) else { return nil }
        return hex.uppercased()
    }
}

#Preview {
    ContentView()
        .environment(RazerController())
}
