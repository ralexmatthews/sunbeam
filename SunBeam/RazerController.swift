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
    /// Charge level 0...100, or nil until the mouse has answered a battery poll.
    private(set) var batteryPercent: Int?
    private(set) var isCharging = false

    @ObservationIgnored private let link = RazerDeviceLink()

    init() {
        link.stateHandler = { [weak self] state in
            self?.isConnected = state.connected
            self?.statusText = state.label
            self?.lastError = state.error
            self?.batteryPercent = state.batteryPercent
            self?.isCharging = state.isCharging
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
        var batteryPercent: Int?
        var isCharging: Bool
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
    private var currentError: String?
    private var batteryPercent: Int?
    private var isCharging = false
    private var batteryTimer: DispatchSourceTimer?

    // Razer's config packet is exactly 90 bytes; that maximum feature-report
    // size uniquely identifies the vendor control interface among the several
    // HID interfaces the mouse/dongle exposes.
    private static let controlReportSize = 90

    // Battery moves slowly and every poll is a USB round trip, so once a minute
    // is plenty; connects and applies trigger an extra read of their own.
    private static let batteryPollInterval: TimeInterval = 60

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
        // The mouse's own charging-status command answers unreliably (see
        // RazerProtocol), so take the wired interface as the truth: it only
        // appears while the cable is attached, which is exactly when it charges.
        isCharging = controls.contains { intProperty($0, kIOHIDProductIDKey) == RazerIDs.productWired }
        lock.unlock()

        guard let chosen else {
            stopBatteryPolling()
            setConnection(false, label: "No Razer mouse found — plug in the dongle")
            return
        }
        let connection = intProperty(chosen, kIOHIDProductIDKey) == RazerIDs.productWired ? "wired" : "wireless"
        setConnection(true, label: "Basilisk V3 Pro — connected (\(connection))")
        startBatteryPolling()
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

            // The mouse is definitely awake right after it accepted a command —
            // the cheapest moment to get a fresh battery reading.
            if failure == nil { pollBattery() }
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

    /// The outcome of one request/response exchange with the device.
    private enum Transaction {
        /// The write itself failed — a hard, user-visible error.
        case failed(String)
        /// The command went through. A reply is attached only when the device
        /// returned a readable one; some dongle firmware never does.
        case acknowledged(RazerReport?)
    }

    /// Send one report, ignoring whatever comes back. Returns a user-facing
    /// error string on hard failure, or nil on success.
    private func send(_ report: RazerReport, to device: IOHIDDevice) -> String? {
        if case .failed(let error) = transact(report, to: device) { return error }
        return nil
    }

    /// Send one report and hand back the device's reply. Callers that need the
    /// reply must check `answers(_:)` on it — an unreadable or mismatched
    /// response is not an error for writes, but carries no data for reads.
    private func transact(_ report: RazerReport, to device: IOHIDDevice) -> Transaction {
        for attempt in 0..<2 {
            let packet = report.packet()
            let setResult = packet.withUnsafeBufferPointer {
                IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0, $0.baseAddress!, $0.count)
            }
            guard setResult == kIOReturnSuccess else {
                RazerDeviceLink.log.error("IOHIDDeviceSetReport failed: \(String(format: "0x%08X", UInt32(bitPattern: setResult)), privacy: .public)")
                return .failed("The mouse didn't accept the command — it may be asleep or disconnected.")
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
            guard getResult == kIOReturnSuccess else { return .acknowledged(nil) }

            // Status 0x01 means "busy" — wait and retry once.
            if response[0] == RazerReport.statusBusy && attempt == 0 {
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            return .acknowledged(RazerReport(packet: Array(response.prefix(min(length, response.count)))))
        }
        return .acknowledged(nil)
    }

    // MARK: - Battery

    /// Read the charge level. Always runs on `queue`, so it can never overlap a
    /// lighting write. A sleeping mouse simply doesn't answer — that is routine,
    /// so a failed poll keeps the last known reading and never raises a
    /// user-facing error. Charging state isn't read here; `updateActiveDevice()`
    /// derives it from which interfaces are present.
    private func pollBattery() {
        lock.lock()
        let device = self.device
        lock.unlock()
        guard let device else { return }

        let request = RazerReport.batteryLevel()
        guard case .acknowledged(let maybeReply) = transact(request, to: device),
              let reply = maybeReply, reply.answers(request) else {
            RazerDeviceLink.log.debug("No battery reading — the mouse is probably asleep")
            return
        }

        lock.lock()
        batteryPercent = reply.batteryPercent
        lock.unlock()
        publish()
    }

    /// Begin polling for battery on `queue`, starting with an immediate read.
    /// Called on every connect; hot-plugging just re-reads through the timer
    /// that is already running.
    private func startBatteryPolling() {
        lock.lock()
        if batteryTimer != nil {
            lock.unlock()
            queue.async { [weak self] in self?.pollBattery() }
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        batteryTimer = timer
        lock.unlock()

        timer.schedule(deadline: .now(),
                       repeating: RazerDeviceLink.batteryPollInterval,
                       leeway: .seconds(10))
        timer.setEventHandler { [weak self] in self?.pollBattery() }
        timer.resume()
    }

    private func stopBatteryPolling() {
        lock.lock()
        let timer = batteryTimer
        batteryTimer = nil
        batteryPercent = nil
        lock.unlock()
        timer?.cancel()
        publish()
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
        currentError = error
        lock.unlock()
        publish()
    }

    /// Re-publish the current state without disturbing the last error. Battery
    /// polls use this so a routine reading can't wipe an error banner the user
    /// just got from Apply.
    private func publish() {
        lock.lock()
        let state = State(connected: connected, label: label, error: currentError,
                          batteryPercent: batteryPercent, isCharging: isCharging)
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
