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
}
