import Cocoa
import FlutterMacOS
import window_ext
import LaunchAtLogin

@main
class AppDelegate: FlutterAppDelegate {
    private let legacyApplicationSupportDirectory = "com.follow.clash"
    private let applicationSupportDirectory = "app.flclashm.client"

    var statusBarController: StatusBarController?
    var zashboardChannel: FlutterMethodChannel?
    var zashboardWindowController: ZashboardWindowController?
    private let productPlatformBridge = ProductPlatformBridge()

    var flutterUIPopover = NSPopover.init()
    
    override init() {
        super.init()
        flutterUIPopover.behavior = NSPopover.Behavior.transient
    }
    
    override func applicationDidFinishLaunching(_ aNotification: Notification) {
        NSLog("AppDelegate: applicationDidFinishLaunching called")
        migrateLegacyApplicationSupportIfNeeded()
        
        guard let mainController = mainFlutterWindow?.contentViewController as? FlutterViewController else {
            NSLog("ERROR: Could not get FlutterViewController from mainFlutterWindow")
            return
        }
        
        
        let popoverContainer = PopoverContainerViewController(flutterViewController: mainController)
        
        flutterUIPopover.contentSize = NSSize(width: 375, height: 600)
        
        flutterUIPopover.contentViewController = popoverContainer
        
        statusBarController = StatusBarController.init(flutterUIPopover)
        
        setupStatusBarChannel(flutterViewController: mainController)
        setupZashboardChannel(flutterViewController: mainController)
        productPlatformBridge.register(with: mainController)

        super.applicationDidFinishLaunching(aNotification)
        
        mainFlutterWindow?.close()
    }

    /// Preserves data created before the desktop bundle identifier was renamed.
    /// The source is intentionally retained so a failed or interrupted import
    /// can be retried safely on the next launch.
    private func migrateLegacyApplicationSupportIfNeeded() {
        guard let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            NSLog("Could not locate Application Support for legacy data import")
            return
        }

        let legacyDirectory = supportDirectory.appendingPathComponent(
            legacyApplicationSupportDirectory,
            isDirectory: true
        )
        let destinationDirectory = supportDirectory.appendingPathComponent(
            applicationSupportDirectory,
            isDirectory: true
        )
        let fileManager = FileManager.default
        var legacyIsDirectory: ObjCBool = false

        guard fileManager.fileExists(
            atPath: legacyDirectory.path,
            isDirectory: &legacyIsDirectory
        ), legacyIsDirectory.boolValue else {
            return
        }

        // A current data directory always wins: never merge or overwrite it.
        guard !fileManager.fileExists(atPath: destinationDirectory.path) else {
            return
        }

        let stagingDirectory = supportDirectory.appendingPathComponent(
            ".\(applicationSupportDirectory)-migration-\(UUID().uuidString)",
            isDirectory: true
        )

        do {
            try fileManager.copyItem(at: legacyDirectory, to: stagingDirectory)
            try fileManager.moveItem(at: stagingDirectory, to: destinationDirectory)
            NSLog("Imported legacy Application Support data into %@", destinationDirectory.path)
        } catch {
            try? fileManager.removeItem(at: stagingDirectory)
            NSLog("Could not import legacy Application Support data: %@", error.localizedDescription)
        }
    }
    
    func setupStatusBarChannel(flutterViewController: FlutterViewController) {
        let channel = FlutterMethodChannel(
            name: "status_bar_icon",
            binaryMessenger: flutterViewController.engine.binaryMessenger
        )
        
        channel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
            switch call.method {
            case "updateIcon":
                if let args = call.arguments as? [String: Any],
                   let isConnected = args["isConnected"] as? Bool {
                    self?.statusBarController?.updateIcon(isVpnConnected: isConnected)
                    result(true)
                } else {
                    result(FlutterError(code: "INVALID_ARGS", message: "Invalid arguments", details: nil))
                }
            default:
                result(FlutterMethodNotImplemented)
            }
        }
        
        NSLog("StatusBar channel set up successfully")
    }

    func setupZashboardChannel(flutterViewController: FlutterViewController) {
        let channel = FlutterMethodChannel(
            name: "zashboard_window",
            binaryMessenger: flutterViewController.engine.binaryMessenger
        )
        zashboardChannel = channel

        channel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
            guard let self = self else { result(nil); return }
            switch call.method {
            case "open":
                guard let args = call.arguments as? [String: Any],
                      let url = args["url"] as? String else {
                    result(FlutterError(code: "INVALID_ARGS", message: "url required", details: nil))
                    return
                }
                if self.zashboardWindowController == nil {
                    self.zashboardWindowController = ZashboardWindowController(onClosed: { [weak self] in
                        self?.zashboardChannel?.invokeMethod("onClosed", arguments: nil)
                    })
                }
                self.zashboardWindowController?.show(urlString: url)
                result(true)
            default:
                result(FlutterMethodNotImplemented)
            }
        }

        NSLog("Zashboard channel set up successfully")
    }

    override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
    
    override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        productPlatformBridge.disconnect()
        WindowExtPlugin.instance?.handleShouldTerminate()
        return .terminateCancel
    }

    override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
      return true
    }
    
    override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let controller = statusBarController {
            if !flutterUIPopover.isShown {
                controller.showPopover(self)
            }
        }
        return true
    }
}
