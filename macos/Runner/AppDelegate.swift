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
    _ = UpdaterController.shared
    super.applicationDidFinishLaunching(notification)
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
