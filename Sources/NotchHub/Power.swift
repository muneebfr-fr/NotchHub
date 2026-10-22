import Foundation
import IOKit.ps

@MainActor
final class PowerMonitor: ObservableObject {
    struct Flash: Equatable {
        let id = UUID()
        let percent: Int
    }

    enum BatteryAlert { case none, low, critical }

    @Published private(set) var flash: Flash?
    @Published private(set) var batteryAlert: BatteryAlert = .none

    private var onAC: Bool
    private var hideWork: DispatchWorkItem?

    init() {
        onAC = Self.isOnAC()
        updateBatteryAlert(onAC: onAC)
        let context = Unmanaged.passUnretained(self).toOpaque()
        // Fires on any power-source change; only the battery → charger transition triggers the animation.
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.powerChanged() }
        }
        if let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }

    private func powerChanged() {
        let nowOnAC = Self.isOnAC()
        updateBatteryAlert(onAC: nowOnAC)
        defer { onAC = nowOnAC }
        guard nowOnAC, !onAC, let percent = Self.batteryPercent() else { return }

        flash = Flash(percent: percent)
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.flash = nil }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2, execute: work)
    }

    // The callback also fires as the charge level changes, so this tracks thresholds without polling.
    private func updateBatteryAlert(onAC: Bool) {
        let alert: BatteryAlert
        if onAC {
            alert = .none
        } else if let percent = Self.batteryPercent() {
            alert = percent <= 10 ? .critical : percent <= 20 ? .low : .none
        } else {
            alert = .none
        }
        if alert != batteryAlert { batteryAlert = alert }
    }

    private static func isOnAC() -> Bool {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let type = IOPSGetProvidingPowerSourceType(info).takeUnretainedValue() as String
        return type == kIOPSACPowerValue
    }

    private static func batteryPercent() -> Int? {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            return current * 100 / max
        }
        return nil
    }
}
