import AppKit

#if DEBUG
// The Settings debug language picker relaunches with this argument. Wait until the old
// instance has finished flushing notes and exited before this one loads them.
if let index = CommandLine.arguments.firstIndex(of: "--debug-relaunch-after"), index + 1 < CommandLine.arguments.count,
   let pid = pid_t(CommandLine.arguments[index + 1]) {
    let deadline = Date().addingTimeInterval(15)
    while NSRunningApplication(processIdentifier: pid) != nil, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
}
#endif
let application = NSApplication.shared
let coordinator = AppCoordinator()
application.delegate = coordinator
application.run()
