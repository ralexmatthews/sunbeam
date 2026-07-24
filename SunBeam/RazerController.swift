//
//  RazerController.swift
//  SunBeam
//
//  Talks to the mouse over IOKit HID. `RazerController` is the small
//  observable surface SwiftUI binds to; the actual USB work lives in the
//  nonisolated `RazerDeviceLink`, which owns the IOHIDManager, opens the
//  vendor control interface, and serializes reports on a background queue.
//

import Foundation
import IOKit
import IOKit.hid
import os

/// The full lighting state the UI wants applied. Passed to the device link,
/// which coalesces rapid updates (e.g. dragging the color wheel).
struct DesiredState: Sendable {
    var mode: RazerMode
    var r: UInt8
    var g: UInt8
    var b: UInt8
    var brightness: UInt8
}

/// Observable view-model. Owns the device link and republishes its state on
/// the main actor for SwiftUI.
@Observable
final class RazerController {
    private(set) var isConnected = false
    private(set) var statusText = "Searching for Basilisk V3 Pro…"
    private(set) var lastError: String?

    @ObservationIgnored private let link = RazerDeviceLink()

    init() {
        link.stateHandler = { [weak self] state in
            self?.isConnected = state.connected
            self?.statusText = state.label
            self?.lastError = state.error
        }
        link.start()
    }

    /// Apply the full lighting state now. Safe to call on every slider tick or
    /// color-wheel drag — the link drops stale intermediate values.
    func apply(mode: RazerMode, r: UInt8, g: UInt8, b: UInt8, brightness: UInt8) {
        link.apply(DesiredState(mode: mode, r: r, g: g, b: b, brightness: brightness))
    }
}

/// All IOKit interaction. Nonisolated so its background-queue send loop and
/// its main-run-loop HID callbacks don't fight the project's default
/// main-actor isolation.
nonisolated final class RazerDeviceLink {
    struct State: Sendable {
        var connected: Bool
        var label: String
        var error: String?
    }

    /// Invoked on the main queue whenever connection or error state changes.
    var stateHandler: ((State) -> Void)?

    private static let log = Logger(subsystem: "ralexmatthews.SunBeam", category: "hid")

    private var manager: IOHIDManager?
    private let queue = DispatchQueue(label: "ralexmatthews.SunBeam.hid")
    private let lock = NSLock()

    // Guarded by `lock`:
    private var device: IOHIDDevice?          // the active interface we send to
    private var controls: [IOHIDDevice] = []  // every open vendor control interface currently present
    private var pending: DesiredState?
    private var draining = false
    private var connected = false
    private var label = "Searching for Basilisk V3 Pro…"

    // Razer's config packet is exactly 90 bytes; that maximum feature-report
    // size uniquely identifies the vendor control interface among the several
    // HID interfaces the mouse/dongle exposes.
    private static let controlReportSize = 90

    private static let matchingCallback: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        Unmanaged<RazerDeviceLink>.fromOpaque(context).takeUnretainedValue().deviceAdded(device)
    }

    private static let removalCallback: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        Unmanaged<RazerDeviceLink>.fromOpaque(context).takeUnretainedValue().deviceRemoved(device)
    }

    // MARK: - Setup

    func start() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager

        let criteria = RazerIDs.products.map { pid in
            [kIOHIDVendorIDKey: RazerIDs.vendorID, kIOHIDProductIDKey: pid] as CFDictionary
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, criteria as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, RazerDeviceLink.matchingCallback, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, RazerDeviceLink.removalCallback, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

        // Existing devices arrive via the matching callback on the next run-loop
        // turn. If none show up, tell the user to plug the dongle in.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let isConnected = self.connected
            self.lock.unlock()
            if !isConnected {
                self.setConnection(false, label: "No Razer mouse found — plug in the dongle")
            }
        }
    }

    // MARK: - Device lifecycle (runs on the main run loop)

    private func deviceAdded(_ device: IOHIDDevice) {
        guard intProperty(device, kIOHIDMaxFeatureReportSizeKey) == RazerDeviceLink.controlReportSize else {
            return  // an input interface, not the control one — ignore
        }

        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            let message: String
            if result == kIOReturnNotPermitted || result == kIOReturnExclusiveAccess {
                message = "macOS blocked access to the mouse. Grant this app access under "
                    + "System Settings ▸ Privacy & Security ▸ Input Monitoring, then relaunch."
            } else {
                message = String(format: "Couldn't open the mouse (IOKit error 0x%08X).",
                                 UInt32(bitPattern: result))
            }
            RazerDeviceLink.log.error("IOHIDDeviceOpen failed: \(String(format: "0x%08X", UInt32(bitPattern: result)), privacy: .public)")
            pushState(error: message)
            return
        }

        let pid = intProperty(device, kIOHIDProductIDKey)
        let connection = pid == RazerIDs.productWired ? "wired" : "wireless"
        RazerDeviceLink.log.info("Opened Basilisk V3 Pro control interface (\(connection, privacy: .public))")

        lock.lock()
        if !controls.contains(where: { CFEqual($0, device) }) { controls.append(device) }
        lock.unlock()
        updateActiveDevice()
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        lock.lock()
        controls.removeAll { CFEqual($0, device) }
        lock.unlock()
        updateActiveDevice()
    }

    /// Choose which of the currently-present control interfaces to send to and
    /// publish the matching connection state. The mouse can be reachable both
    /// wired and over the dongle at once (e.g. charging while paired); we prefer
    /// the wired interface, so plugging the cable in shows "wired" and unplugging
    /// falls back to "wireless" without needing a relaunch.
    private func updateActiveDevice() {
        lock.lock()
        // Lower rank wins: wired (0x00AA) over the dongle (0x00AB).
        let chosen = controls.min { rank($0) < rank($1) }
        device = chosen
        lock.unlock()

        guard let chosen else {
            setConnection(false, label: "No Razer mouse found — plug in the dongle")
            return
        }
        let connection = intProperty(chosen, kIOHIDProductIDKey) == RazerIDs.productWired ? "wired" : "wireless"
        setConnection(true, label: "Basilisk V3 Pro — connected (\(connection))")
    }

    /// Sort key for picking the active interface: wired before wireless.
    private func rank(_ device: IOHIDDevice) -> Int {
        intProperty(device, kIOHIDProductIDKey) == RazerIDs.productWired ? 0 : 1
    }

    // MARK: - Applying state (coalesced onto the background queue)

    func apply(_ state: DesiredState) {
        lock.lock()
        pending = state
        let alreadyDraining = draining
        draining = true
        lock.unlock()

        if !alreadyDraining {
            queue.async { [weak self] in self?.drain() }
        }
    }

    /// Background worker: always sends the most recent pending state, dropping
    /// any intermediate values that piled up while a send was in flight.
    private func drain() {
        while true {
            lock.lock()
            guard let state = pending else {
                draining = false
                lock.unlock()
                return
            }
            pending = nil
            let device = self.device
            lock.unlock()

            guard let device else {
                pushState(error: "Mouse not connected.")
                continue
            }

            var failure: String?
            for report in reports(for: state) {
                if let error = send(report, to: device) {
                    failure = error
                    break
                }
            }
            pushState(error: failure)
        }
    }

    private func reports(for state: DesiredState) -> [RazerReport] {
        var reports: [RazerReport] = [.brightness(state.brightness)]
        switch state.mode {
        case .staticColor: reports.append(.staticColor(r: state.r, g: state.g, b: state.b))
        case .breathing: reports.append(.breathing(r: state.r, g: state.g, b: state.b))
        case .spectrum: reports.append(.spectrum())
        case .off: reports.append(.off())
        }
        return reports
    }

    /// Send one report and read the acknowledgement. Returns a user-facing
    /// error string on hard failure, or nil on success.
    private func send(_ report: RazerReport, to device: IOHIDDevice) -> String? {
        for attempt in 0..<2 {
            let packet = report.packet()
            let setResult = packet.withUnsafeBufferPointer {
                IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0, $0.baseAddress!, $0.count)
            }
            guard setResult == kIOReturnSuccess else {
                RazerDeviceLink.log.error("IOHIDDeviceSetReport failed: \(String(format: "0x%08X", UInt32(bitPattern: setResult)), privacy: .public)")
                return "The mouse didn't accept the command — it may be asleep or disconnected."
            }

            // The device needs a beat to process before we read its reply or
            // send the next command.
            Thread.sleep(forTimeInterval: 0.031)

            var response = [UInt8](repeating: 0, count: 90)
            var length = response.count
            let getResult = response.withUnsafeMutableBufferPointer {
                IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 0, $0.baseAddress!, &length)
            }
            // Some firmware/dongle combinations don't return a readable feature
            // response; the SetReport already succeeded, so treat that as fine.
            guard getResult == kIOReturnSuccess else { return nil }

            // Status 0x01 means "busy" — wait and retry once.
            if response[0] == 0x01 && attempt == 0 {
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            return nil
        }
        return nil
    }

    // MARK: - State plumbing

    private func setConnection(_ isConnected: Bool, label newLabel: String) {
        lock.lock()
        connected = isConnected
        label = newLabel
        lock.unlock()
        pushState(error: nil)
    }

    private func pushState(error: String?) {
        lock.lock()
        let state = State(connected: connected, label: label, error: error)
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.stateHandler?(state) }
    }

    private func intProperty(_ device: IOHIDDevice, _ key: String) -> Int? {
        guard let value = IOHIDDeviceGetProperty(device, key as CFString),
              CFGetTypeID(value) == CFNumberGetTypeID() else { return nil }
        var result = 0
        CFNumberGetValue((value as! CFNumber), .intType, &result)
        return result
    }
}
