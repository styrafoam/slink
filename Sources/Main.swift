import AppKit

final class SlinkApplication: NSObject, NSApplicationDelegate {
    private let timing = TimingService()
    private var spring: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        createSpringMenu()
        timing.setChannels(left: true, right: true)
        timing.start()
    }

    private func createSpringMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = SpringIcon.image()
        item.button?.toolTip = "slink"
        item.button?.setAccessibilityLabel("slink spring menu")
        let menu = NSMenu()
        let commands: [(String, Selector)] = [
            ("Refresh", #selector(refresh)),
            ("Prioritize Heating", #selector(heat)),
            ("Prioritize Cooling", #selector(cool)),
            ("Quiet mode", #selector(quiet))
        ]
        for (title, selector) in commands {
            let entry = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            entry.target = self
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApp
        menu.addItem(quit)
        item.menu = menu
        spring = item
    }

    @objc private func refresh() { timing.refresh() }
    @objc private func heat() { timing.setMode(.heating) }
    @objc private func cool() { timing.setMode(.cooling) }
    @objc private func quiet() { timing.setMode(.normal) }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { timing.stop() }
}

@main enum SlinkMain {
    static func main() {
        if CommandLine.arguments.contains("--self-check") {
            print("slink: independent local input-sampling utility")
            print("interface: menu-bar-only; activation: accessory")
            for mode in SamplingMode.allCases {
                print("\(mode.rawValue): \(mode.configuration.intervalNanoseconds) ns sampling interval")
            }
            return
        }
        let app = NSApplication.shared
        let delegate = SlinkApplication()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
