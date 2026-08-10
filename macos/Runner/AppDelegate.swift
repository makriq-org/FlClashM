import Cocoa
import FlutterMacOS
import window_ext
import LaunchAtLogin

@main
class AppDelegate: FlutterAppDelegate {
    var statusBarController: StatusBarController?
    var zashboardChannel: FlutterMethodChannel?
    var zashboardWindowController: ZashboardWindowController?

    var flutterUIPopover = NSPopover.init()
    
    override init() {
        super.init()
        flutterUIPopover.behavior = NSPopover.Behavior.transient
    }
    
    override func applicationDidFinishLaunching(_ aNotification: Notification) {
        NSLog("AppDelegate: applicationDidFinishLaunching called")
        
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

        super.applicationDidFinishLaunching(aNotification)
        
        mainFlutterWindow?.close()
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
