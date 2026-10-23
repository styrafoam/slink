import Foundation

private var passed = 0
private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError("FAIL: \(message)") }
    passed += 1
}

private final class Fixture {
    private let lock = NSLock()
    var permission = true
    var focus = true
    var left = false
    var right = false
    var reads = 0
    var focusReads = 0
    var permissionReads = 0

    func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }
    func set(left: Bool? = nil, right: Bool? = nil, permission: Bool? = nil, focus: Bool? = nil) {
        withLock {
            if let left { self.left = left }
            if let right { self.right = right }
            if let permission { self.permission = permission }
            if let focus { self.focus = focus }
        }
    }
    func sampleCount() -> Int { withLock { reads } }
    func service() -> TimingService {
        TimingService(permissionProvider: { [self] in
            withLock { permissionReads += 1; return permission }
        }, focusProvider: { [self] in
            withLock { focusReads += 1; return focus }
        }, buttonProvider: { [self] in
            withLock { reads += 1; return (left, right) }
        }, observeWorkspace: false, managesProcessActivity: false)
    }
}

private func run(for seconds: TimeInterval) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

@main
struct TimingTests {
    static func main() {
        check(SamplingMode.heating.configuration.intervalNanoseconds == 1_000_000, "Heating is 1 ms")
        check(SamplingMode.normal.configuration.intervalNanoseconds == 8_000_000, "Quiet default is 8 ms")
        check(SamplingMode.cooling.configuration.intervalNanoseconds == 32_000_000, "Cooling is 32 ms")
        check(SamplingMode.heating.configuration.strict, "Heating requests strict timer delivery")
        check(SamplingMode.heating.configuration.requestsLatencyActivity, "Heating requests process activity")
        check(!SamplingMode.normal.configuration.requestsLatencyActivity, "Quiet has no special process activity")
        check(!SamplingMode.cooling.configuration.requestsLatencyActivity, "Cooling has no special process activity")
        check(SamplingMode.heating.configuration.qos == .userInteractive, "Heating queue has interactive QoS")
        check(SamplingMode.cooling.configuration.qos == .utility, "Cooling queue has utility QoS")

        let fixture = Fixture()
        let service = fixture.service()
        var samples: [InputSample] = []
        var permissions: [Bool] = []
        service.onSample = { samples.append($0) }
        service.onPermissionChanged = { permissions.append($0) }
        service.setChannels(left: true, right: true)
        service.start()
        run(for: 0.07)
        check(permissions == [true], "Initial permission reported on main queue")
        check(samples.last?.focusedWindowAvailable == true, "Authorized focus provider is actually consumed")
        check(samples.last?.leftCount == 0 && samples.last?.rightCount == 0, "No fabricated clicks")
        fixture.set(left: true)
        service.refresh(); run(for: 0.02)
        check(samples.last?.leftCount == 1 && samples.last?.leftHeld == true, "Physical left press counted")
        service.refresh(); run(for: 0.02)
        check(samples.last?.leftCount == 1, "Held button is not recounted")
        fixture.set(left: false, right: true)
        service.refresh(); run(for: 0.02)
        check(samples.last?.leftHeld == false && samples.last?.rightCount == 1, "Independent right press counted")
        fixture.set(right: false)
        service.refresh()
        service.setChannels(left: false, right: true)
        fixture.set(left: true)
        service.refresh(); run(for: 0.02)
        check(samples.last?.leftCount == 1 && samples.last?.leftHeld == false, "Disabled channel does not count")
        service.setChannels(left: true, right: true)
        run(for: 0.02)
        check(samples.last?.leftCount == 1, "Enabling a held channel does not invent a press")
        fixture.set(left: false)
        service.refresh()
        fixture.set(left: true)
        service.refresh(); run(for: 0.02)
        check(samples.last?.leftCount == 2, "Rearmed physical transition counted")

        fixture.set(permission: false)
        let readsBeforeRevocation = fixture.sampleCount()
        service.refresh(); run(for: 0.06)
        check(permissions == [true, false], "Permission loss reported")
        check(fixture.sampleCount() == readsBeforeRevocation, "No button reads without permission")
        check(samples.last?.focusedWindowAvailable == false && samples.last?.leftHeld == false,
            "Permission loss clears observation state")
        fixture.set(left: false, permission: true, focus: false)
        service.refresh(); run(for: 0.02)
        check(permissions == [true, false, true], "Permission restore reported")
        check(samples.last?.focusedWindowAvailable == false, "Missing focused window is retained as false")
        let focusReads = fixture.withLock { fixture.focusReads }
        service.refresh(); run(for: 0.01)
        check(fixture.withLock { fixture.focusReads } > focusReads, "Refresh really rechecks focused-window availability")

        service.setMode(.heating)
        let fastStart = fixture.sampleCount()
        run(for: 0.24)
        let heatingReads = fixture.sampleCount() - fastStart
        service.setMode(.cooling)
        let slowStart = fixture.sampleCount()
        run(for: 0.24)
        let coolingReads = fixture.sampleCount() - slowStart
        check(heatingReads > coolingReads * 5 && heatingReads > 20, "Selected schedules change actual sampler cadence")
        check(samples.last?.mode == .cooling, "Sample includes actual running mode")
        service.setMode(.normal)
        run(for: 0.02)
        check(samples.last?.mode == .normal, "Quiet returns to default mode")

        service.setMode(.heating)
        service.setSessionActive(false)
        run(for: 0.02)
        let lockedReads = fixture.sampleCount()
        run(for: 0.05)
        check(fixture.sampleCount() == lockedReads, "Locked session has no observations")
        check(samples.last?.mode == .normal && samples.last?.leftHeld == false, "Lock resets mode and held state")
        service.setMode(.heating)
        service.refresh(); run(for: 0.02)
        check(fixture.sampleCount() == lockedReads && samples.last?.mode == .normal,
            "Locked session rejects high-frequency mode and explicit refresh")
        service.setSessionActive(true)
        run(for: 0.03)
        check(fixture.sampleCount() > lockedReads, "Wake resumes default observation")
        check(samples.last?.mode == .normal, "Wake cannot restore heating")
        service.stop()
        let stoppedReads = fixture.sampleCount()
        run(for: 0.04)
        check(fixture.sampleCount() == stoppedReads, "Stop cancels sampling")
        check(samples.allSatisfy { $0.observedAt.timeIntervalSince1970 > 0 }, "Observations carry real timestamps")

        let targetLock = NSLock()
        var inspectedTargets: [Int32] = []
        let targeting = TimingService(permissionProvider: { true }, targetFocusProvider: { pid in
            targetLock.lock(); defer { targetLock.unlock() }
            inspectedTargets.append(pid)
            return pid == 123
        }, buttonProvider: { (false, false) }, observeWorkspace: false, managesProcessActivity: false)
        var targetSamples: [InputSample] = []
        targeting.onSample = { targetSamples.append($0) }
        targeting.start(); run(for: 0.01)
        targetLock.lock(); let initialTargets = inspectedTargets; targetLock.unlock()
        check(initialTargets == [0], "No selected PID defaults to active-application focus provider")
        targeting.setTarget(pid: 123); run(for: 0.01)
        check(targetSamples.last?.focusedWindowAvailable == true, "Selected PID immediately refreshes focus")
        targetLock.lock(); let selectedTargets = inspectedTargets; targetLock.unlock()
        check(selectedTargets == [0, 123], "Selected PID is passed to focused-window query")
        targeting.setTarget(pid: 123)
        targetLock.lock(); let unchangedTargets = inspectedTargets; targetLock.unlock()
        check(unchangedTargets == selectedTargets, "Saving unchanged target does not repeat AX queries")
        targeting.setTarget(pid: 456); run(for: 0.01)
        check(targetSamples.last?.focusedWindowAvailable == false, "New unavailable target clears old focus state")
        targeting.setTarget(pid: -1); run(for: 0.01)
        targetLock.lock(); let resetTargets = inspectedTargets; targetLock.unlock()
        check(resetTargets.last == 0, "Clearing or invalid target restores active application mode")
        targeting.stop()

        let headless = Fixture()
        var timestampReads = 0
        let background = TimingService(permissionProvider: { true }, focusProvider: { true },
            buttonProvider: {
                headless.withLock { headless.reads += 1; return (headless.left, headless.right) }
            }, clock: {
                headless.withLock { timestampReads += 1 }
                return Date()
            }, observeWorkspace: false, managesProcessActivity: false)
        background.setChannels(left: true, right: true)
        background.start(); run(for: 0.04)
        check(headless.sampleCount() > 1, "Menu-only mode continues actual input observation without display callbacks")
        check(headless.withLock { timestampReads } == 0, "Menu-only mode does not construct unused timestamped display samples")
        background.onSample = { _ in }
        background.refresh(); run(for: 0.02)
        check(headless.withLock { timestampReads } > 0, "An explicit observer can still receive observations")
        background.stop()
        print("PASS: \(passed) independent timing checks; heating \(heatingReads) samples, cooling \(coolingReads) samples in 240 ms each. No OS input or permission APIs invoked.")
    }
}
