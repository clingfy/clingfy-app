import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    // First, before Dart starts Sentry: see NativeLogger.installLifecycleHooks.
    NativeLogger.installLifecycleHooks()
    _ = UpdaterController.shared
    // Only if Flutter implements it, which it does not: FlutterAppDelegate
    // observes the did-finish-launching notification rather than implementing
    // this method (FlutterAppLifecycleDelegate.h). Calling super regardless
    // raised "unrecognized selector" on every launch, out of AppKit's launch
    // notification, and NativeLogger logged it as an uncaught exception.
    if Self.superclassImplementsDidFinishLaunching {
      super.applicationDidFinishLaunching(notification)
    }
  }

  static var superclassImplementsDidFinishLaunching: Bool {
    FlutterAppDelegate.instancesRespond(
      to: #selector(NSApplicationDelegate.applicationDidFinishLaunching(_:)))
  }

  override func application(_ application: NSApplication, open urls: [URL]) {
    var didQueueValidProject = false

    for url in urls {
      do {
        let projectRef = try ProjectOpenValidator.validateProjectURL(url)
        ProjectOpenCoordinator.shared.enqueueProjectPath(projectRef.rootURL.path)
        didQueueValidProject = true
        NativeLogger.i(
          "ProjectOpen",
          "Accepted Finder project open request",
          context: ["projectPath": projectRef.rootURL.path]
        )
      } catch {
        NativeLogger.w(
          "ProjectOpen",
          "Ignoring invalid Finder project open request",
          context: ["url": url.path, "error": error.localizedDescription]
        )
      }
    }

    if didQueueValidProject {
      NSApp.activate(ignoringOtherApps: true)
    }
  }
}
