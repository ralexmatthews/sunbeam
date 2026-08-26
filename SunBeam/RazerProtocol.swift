//
//  RazerProtocol.swift
//  SunBeam
//
//  The Razer USB protocol: a fixed 90-byte packet sent as an HID feature
//  report. Byte layout and command arguments were taken from the OpenRazer
//  Linux driver (razermouse_driver.c / razerchromacommon.c). Everything here
//  is pure data — no IOKit — so it is trivial to unit-test and extend.
//

import Foundation

/// USB identifiers for the Basilisk V3 Pro. The mouse exposes the same
/// lighting protocol whether it is talking over the HyperSpeed dongle or a
/// charging cable; only the product id differs.
nonisolated enum RazerIDs {
    static let vendorID = 0x1532
    static let productWireless = 0x00AB  // HyperSpeed USB dongle
    static let productWired = 0x00AA     // wired / charging cable

    static let products = [productWireless, productWired]
}

/// The lighting effects this app can set. `VARSTORE` writes persist to the
/// mouse's onboard memory, so a chosen effect survives quitting the app and
/// power-cycling the mouse.
nonisolated enum RazerMode: String, CaseIterable, Identifiable, Sendable {
    case staticColor
    case spectrum
    case breathing
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .staticColor: return "Static"
        case .spectrum: return "Spectrum"
        case .breathing: return "Breathing"
        case .off: return "Off"
        }
    }

    /// Whether the chosen color is meaningful for this effect.
    var usesColor: Bool { self == .staticColor || self == .breathing }
}

/// A single Razer command packet. Construct one with the factory methods
/// below and call `packet()` to get the 90 bytes to hand to IOKit.
nonisolated struct RazerReport {
    // Persist to onboard memory rather than volatile RAM.
    private static let varStore: UInt8 = 0x01
    // Address every lighting zone at once.
    private static let allZones: UInt8 = 0x00
    // Razer's transaction id for the Basilisk V3 Pro family.
    static let transactionID: UInt8 = 0x1F

    // Reply status codes we act on. Razer also defines 0x00 new, 0x03 failure,
    // 0x04 timeout and 0x05 not-supported; for our purposes all of those mean
    // "the arguments in this reply are not meaningful".
    static let statusBusy: UInt8 = 0x01
    static let statusSuccessful: UInt8 = 0x02

    var status: UInt8 = 0x00
    var transaction: UInt8 = RazerReport.transactionID
    var commandClass: UInt8 = 0x00
    var commandID: UInt8 = 0x00
    var dataSize: UInt8 = 0x00
    var arguments = [UInt8](repeating: 0, count: 80)

    /// Serialize into the 90-byte on-the-wire representation, including the
    /// XOR checksum over bytes 2...87.
    func packet() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 90)
        bytes[0] = status
        bytes[1] = transaction
        // bytes[2...3] remaining-packet count, always 0 for our single-packet commands
        // bytes[4] protocol type, always 0
        bytes[5] = dataSize
        bytes[6] = commandClass
        bytes[7] = commandID
        for i in 0..<80 {
            bytes[8 + i] = arguments[i]
        }
        var crc: UInt8 = 0
        for i in 2...87 {
            crc ^= bytes[i]
        }
        bytes[88] = crc
        // bytes[89] reserved, 0
        return bytes
    }

    private static func make(class cls: UInt8, id: UInt8, size: UInt8, _ args: [UInt8]) -> RazerReport {
        var report = RazerReport()
        report.commandClass = cls
        report.commandID = id
        report.dataSize = size
        for (i, byte) in args.enumerated() where i < 80 {
            report.arguments[i] = byte
        }
        return report
    }

    // MARK: - Lighting commands (extended matrix, class 0x0F)

    static func staticColor(r: UInt8, g: UInt8, b: UInt8) -> RazerReport {
        make(class: 0x0F, id: 0x02, size: 0x09,
             [varStore, allZones, 0x01, 0x00, 0x00, 0x01, r, g, b])
    }

    static func spectrum() -> RazerReport {
        make(class: 0x0F, id: 0x02, size: 0x06,
             [varStore, allZones, 0x03, 0x00, 0x00, 0x00])
    }

    static func breathing(r: UInt8, g: UInt8, b: UInt8) -> RazerReport {
        make(class: 0x0F, id: 0x02, size: 0x09,
             [varStore, allZones, 0x02, 0x01, 0x00, 0x01, r, g, b])
    }

    static func off() -> RazerReport {
        make(class: 0x0F, id: 0x02, size: 0x06,
             [varStore, allZones, 0x00, 0x00, 0x00, 0x00])
    }

    /// Brightness 0...255 (class 0x0F, command 0x04).
    static func brightness(_ value: UInt8) -> RazerReport {
        make(class: 0x0F, id: 0x04, size: 0x03,
             [varStore, allZones, value])
    }

    /// Read firmware version — used only as a lightweight "is the mouse
    /// responding?" probe (class 0x00, command 0x81).
    static func firmwareVersion() -> RazerReport {
        make(class: 0x00, id: 0x81, size: 0x02, [0x00, 0x00])
    }

    // MARK: - Battery (misc commands, class 0x07)

    /// Ask for the battery charge level (class 0x07, command 0x80). The reply
    /// carries the raw 0...255 level in `arguments[1]`.
    static func batteryLevel() -> RazerReport {
        make(class: 0x07, id: 0x80, size: 0x02, [0x00, 0x00])
    }

    // There is also a charging-status command (class 0x07, command 0x84), but
    // on the Basilisk V3 Pro it answers unreliably — the reply flaps regardless
    // of whether the cable is attached. `RazerDeviceLink` derives charging from
    // the presence of the wired interface instead; don't reintroduce 0x84.
}

// MARK: - Reading replies

// Declared in an extension so `RazerReport()` keeps its implicit initializer.
nonisolated extension RazerReport {
    /// Parse a 90-byte reply read back from the device — the inverse of
    /// `packet()`. The checksum is deliberately not verified: some dongle
    /// firmware leaves it zeroed even on an otherwise good reply.
    init?(packet bytes: [UInt8]) {
        guard bytes.count == 90 else { return nil }
        self.init()
        status = bytes[0]
        transaction = bytes[1]
        dataSize = bytes[5]
        commandClass = bytes[6]
        commandID = bytes[7]
        arguments = Array(bytes[8..<88])
    }

    /// Whether this reply answers `request` — the control interface is shared,
    /// so a reply left over from another command can turn up on a read.
    func answers(_ request: RazerReport) -> Bool {
        status == RazerReport.statusSuccessful
            && commandClass == request.commandClass
            && commandID == request.commandID
    }

    /// Charge level of a `batteryLevel()` reply, as a 0...100 percentage.
    var batteryPercent: Int {
        Int((Double(arguments[1]) / 255 * 100).rounded())
    }
}
