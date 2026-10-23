import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum SamplingMode: String, CaseIterable {
    case normal, heating, cooling

    var configuration: SamplingConfiguration {
        switch self {
        case .normal:
            return SamplingConfiguration(intervalNanoseconds: 8_000_000,
                leewayNanoseconds: 1_000_000, qos: .default, strict: false,
                requestsLatencyActivity: false)
        case .heating:
            return SamplingConfiguration(intervalNanoseconds: 1_000_000,
                leewayNanoseconds: 100_000, qos: .userInteractive, strict: true,
                requestsLatencyActivity: true)
        case .cooling:
            return SamplingConfiguration(intervalNanoseconds: 32_000_000,
                leewayNanoseconds: 8_000_000, qos: .utility, strict: false,
                requestsLatencyActivity: false)
        }
    }
}

struct SamplingConfiguration {
    let intervalNanoseconds: Int
    let leewayNanoseconds: Int
    let qos: DispatchQoS.QoSClass
    let strict: Bool
    let requestsLatencyActivity: Bool
}

struct InputSample {
    let leftCount: Int
    let rightCount: Int
    let leftHeld: Bool
    let rightHeld: Bool
    let focusedWindowAvailable: Bool
    let observedAt: Date
    let mode: SamplingMode
}

/// Observes button transitions; it never posts, suppresses, or delays input.
/// Timing modes control this process's observation cadence, not global input latency.
final class TimingService {
    private let control = DispatchQueue(label: "local.slink.sampling.control")
    private let queueKey = DispatchSpecificKey<Bool>()
    private let callbacks = NSLock()
    private var sampleCallback: ((InputSample) -> Void)?
    private var permissionCallback: ((Bool) -> Void)?
    private var deliveryGeneration: UInt64 = 0

    var onSample: ((InputSample) -> Void)? {
        get { locked { sampleCallback } }
        set { locked { sampleCallback = newValue } }
    }
    var onPermissionChanged: ((Bool) -> Void)? {
        get { locked { permissionCallback } }
        set { locked { permissionCallback = newValue } }
    }

    private let permissionProvider: () -> Bool
    private let focusProvider: (Int32) -> Bool
    private let buttonProvider: () -> (left: Bool, right: Bool)
    private let clock: () -> Date
    private let managesProcessActivity: Bool
    private var workspaceObservers: [NSObjectProtocol] = []
    private var timer: DispatchSourceTimer?
    private var timerGeneration: UInt64 = 0
    private var activity: NSObjectProtocol?
    private var running = false
    private var sessionActive = true
    private var mode = SamplingMode.normal
    private var targetPID: Int32 = 0
    private var allowed = false
    private var permissionReported = false
    private var leftEnabled = false
    private var rightEnabled = false
    private var leftCount = 0
    private var rightCount = 0
    private var previousLeft: Bool?
    private var previousRight: Bool?
    private var focusedWindowAvailable = false
    private var nextPermissionCheck: UInt64 = 0
    private var nextFocusCheck: UInt64 = 0
    private var nextPublication: UInt64 = 0

    /// The injected providers make timing and edge counting testable without input,
    /// privacy prompts, a GUI session, or any interaction with another application.
    init(permissionProvider: @escaping () -> Bool = TimingService.permissionAvailable,
         focusProvider: (() -> Bool)? = nil,
         targetFocusProvider: ((Int32) -> Bool)? = nil,
         buttonProvider: @escaping () -> (left: Bool, right: Bool) = TimingService.physicalButtons,
         clock: @escaping () -> Date = Date.init,
         observeWorkspace: Bool = true,
         managesProcessActivity: Bool = true) {
        self.permissionProvider = permissionProvider
        if let targetFocusProvider {
            self.focusProvider = targetFocusProvider
        } else if let focusProvider {
            self.focusProvider = { _ in focusProvider() }
        } else {
            self.focusProvider = TimingService.focusedWindowExists
        }
        self.buttonProvider = buttonProvider
        self.clock = clock
        self.managesProcessActivity = managesProcessActivity
        control.setSpecific(key: queueKey, value: true)
        if observeWorkspace {
            let notifications = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
                workspaceObservers.append(notifications.addObserver(forName: name, object: nil,
                    queue: .main) { [weak self] _ in self?.setSessionActive(false) })
            }
            for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
                workspaceObservers.append(notifications.addObserver(forName: name, object: nil,
                    queue: .main) { [weak self] _ in self?.setSessionActive(true) })
            }
            workspaceObservers.append(notifications.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil,
                queue: .main) { [weak self] _ in self?.refresh() })
        }
    }

    deinit {
        stop()
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers { center.removeObserver(observer) }
    }

    func start() {
        sync {
            guard !running else { return }
            running = true
            nextPermissionCheck = 0
            nextFocusCheck = 0
            rebuildTimer()
            sample(forceRefresh: true, forcePublish: true)
        }
    }

    func setMode(_ requestedMode: SamplingMode) {
        sync {
            // A sleeping or locked session cannot retain a high-frequency mode.
            mode = sessionActive ? requestedMode : .normal
            if running { rebuildTimer(); sample(forceRefresh: true, forcePublish: true) }
        }
    }

    func setChannels(left: Bool, right: Bool) {
        sync {
            if leftEnabled != left { previousLeft = nil }
            if rightEnabled != right { previousRight = nil }
            leftEnabled = left
            rightEnabled = right
            if running { sample(forceRefresh: false, forcePublish: true) }
        }
    }

    /// Zero follows the active application. A positive PID checks
    /// only that selected application's focused-window reference.
    func setTarget(pid: Int32) {
        sync {
            let requestedPID = max(0, pid)
            guard targetPID != requestedPID else { return }
            targetPID = requestedPID
            focusedWindowAvailable = false
            nextFocusCheck = 0
            if running { sample(forceRefresh: false, forcePublish: true) }
        }
    }

    /// A real one-shot permission/focus/button refresh, independent of timer cadence.
    func refresh() {
        sync {
            nextPermissionCheck = 0
            nextFocusCheck = 0
            if running { sample(forceRefresh: true, forcePublish: true) }
        }
    }

    func stop() {
        sync {
            running = false
            mode = .normal
            cancelTimer()
            endActivity()
            resetHeldState()
            focusedWindowAvailable = false
            locked { deliveryGeneration &+= 1 }
        }
    }

    // Internal so tests can model sleep/lock without posting workspace notifications.
    func setSessionActive(_ active: Bool) {
        sync {
            sessionActive = active
            mode = .normal
            resetHeldState()
            focusedWindowAvailable = false
            locked { deliveryGeneration &+= 1 }
            nextPermissionCheck = 0
            nextFocusCheck = 0
            rebuildTimer()
            if running { sample(forceRefresh: true, forcePublish: true) }
        }
    }

    private func rebuildTimer() {
        cancelTimer()
        endActivity()
        guard running && sessionActive else { return }
        let config = mode.configuration
        if config.requestsLatencyActivity && managesProcessActivity {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                reason: "Observe physical button transitions at the selected local sampling cadence")
        }
        let worker = DispatchQueue(label: "local.slink.sampling.sampler", qos: DispatchQoS(qosClass: config.qos, relativePriority: 0))
        let source = DispatchSource.makeTimerSource(flags: config.strict ? .strict : [], queue: worker)
        let generation = timerGeneration
        source.schedule(deadline: .now() + .nanoseconds(config.intervalNanoseconds),
            repeating: .nanoseconds(config.intervalNanoseconds),
            leeway: .nanoseconds(config.leewayNanoseconds))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // A synchronous hop bounds backlog to one tick. The source cannot
            // accumulate observations while a permission/focus query is in flight.
            self.sync {
                guard self.timerGeneration == generation else { return }
                self.sample(forceRefresh: false, forcePublish: false)
            }
        }
        timer = source
        source.resume()
    }

    private func cancelTimer() {
        timerGeneration &+= 1
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
    }

    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    private func resetHeldState() {
        previousLeft = nil
        previousRight = nil
    }

    private func sample(forceRefresh: Bool, forcePublish: Bool) {
        guard running else { return }
        let tick = DispatchTime.now().uptimeNanoseconds
        if !sessionActive {
            publish(left: false, right: false, force: forcePublish, tick: tick)
            return
        }
        if forceRefresh || tick >= nextPermissionCheck {
            let currentPermission = permissionProvider()
            if !permissionReported || currentPermission != allowed {
                allowed = currentPermission
                permissionReported = true
                resetHeldState()
                notifyPermission(currentPermission)
            }
            nextPermissionCheck = tick &+ 1_000_000_000
        }
        if !allowed {
            focusedWindowAvailable = false
            resetHeldState()
            publish(left: false, right: false, force: forcePublish, tick: tick)
            return
        }
        if forceRefresh || tick >= nextFocusCheck {
            focusedWindowAvailable = focusProvider(targetPID)
            nextFocusCheck = tick &+ 500_000_000
        }
        // No keyboard state, cursor location, event tap, or event payload is read.
        let buttons = buttonProvider()
        let left = leftEnabled && buttons.left
        let right = rightEnabled && buttons.right
        if leftEnabled {
            if previousLeft == false && left { leftCount &+= 1 }
            previousLeft = left
        }
        if rightEnabled {
            if previousRight == false && right { rightCount &+= 1 }
            previousRight = right
        }
        publish(left: left, right: right, force: forcePublish, tick: tick)
    }

    private func publish(left: Bool, right: Bool, force: Bool, tick: UInt64) {
        guard force || tick >= nextPublication else { return }
        guard locked({ sampleCallback != nil }) else { return }
        // The worker still samples every configured tick; display delivery is
        // coalesced so heating does not enqueue 1,000 UI updates per second.
        nextPublication = tick &+ 33_333_333
        let value = InputSample(leftCount: leftCount, rightCount: rightCount,
            leftHeld: left, rightHeld: right, focusedWindowAvailable: focusedWindowAvailable,
            observedAt: clock(), mode: mode)
        let generation = locked { deliveryGeneration }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let callback = self.locked { self.deliveryGeneration == generation ? self.sampleCallback : nil }
            callback?(value)
        }
    }

    private func notifyPermission(_ value: Bool) {
        let generation = locked { deliveryGeneration }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let callback = self.locked { self.deliveryGeneration == generation ? self.permissionCallback : nil }
            callback?(value)
        }
    }

    private func sync<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true { return body() }
        return control.sync(execute: body)
    }

    private func locked<T>(_ body: () -> T) -> T {
        callbacks.lock()
        defer { callbacks.unlock() }
        return body()
    }

    private static func permissionAvailable() -> Bool {
        AXIsProcessTrusted() && CGPreflightPostEventAccess()
    }

    private static func physicalButtons() -> (left: Bool, right: Bool) {
        (CGEventSource.buttonState(.hidSystemState, button: .left),
         CGEventSource.buttonState(.hidSystemState, button: .right))
    }

    private static func focusedWindowExists(pid: Int32) -> Bool {
        // Only reference existence is retained. No application identity, window
        // title, accessibility text, or UI contents leave this function.
        let application: AXUIElement
        if pid > 0 {
            application = AXUIElementCreateApplication(pid)
        } else {
            let system = AXUIElementCreateSystemWide()
            _ = AXUIElementSetMessagingTimeout(system, 0.02)
            var applicationValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString,
                &applicationValue) == .success, let applicationValue,
                CFGetTypeID(applicationValue) == AXUIElementGetTypeID() else { return false }
            application = unsafeBitCast(applicationValue, to: AXUIElement.self)
        }
        _ = AXUIElementSetMessagingTimeout(application, 0.02)
        var window: CFTypeRef?
        return AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString,
            &window) == .success && window != nil
    }
}
