import Cocoa
import FlutterMacOS
import window_manager
import LaunchAtLogin
import desktop_multi_window
import screen_retriever_macos

class MainFlutterWindow: NSWindow {
    override func awakeFromNib() {
        let flutterViewController = FlutterViewController()
        let windowFrame = self.frame
        self.contentViewController = flutterViewController
        self.setFrame(windowFrame, display: true)
        
        FlutterMethodChannel(
            name: "launch_at_startup", binaryMessenger: flutterViewController.engine.binaryMessenger
        )
        .setMethodCallHandler { (_ call: FlutterMethodCall, result: @escaping FlutterResult) in
            switch call.method {
            case "launchAtStartupIsEnabled":
                result(LaunchAtLogin.isEnabled)
            case "launchAtStartupSetEnabled":
                if let arguments = call.arguments as? [String: Any] {
                    LaunchAtLogin.isEnabled = (arguments["setEnabledValue"] as? Bool) ?? false
                }
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
        
        RegisterGeneratedPlugins(registry: flutterViewController)

        // Register ONLY the plugins the editor sub-window needs: window_manager
        // (size/show/focus/close) and its screen_retriever helper. Crucially we
        // do NOT call RegisterGeneratedPlugins here — it also re-registers
        // window_ext, whose *static* `instance` routes app termination. That
        // overwrite sent the quit signal to the editor engine (which ignores it
        // → app couldn't quit) and pinned the sub-engine alive as a zombie
        // ("AutoFill") process. Keeping the set minimal leaves window_ext (and
        // tray etc.) bound to the main engine. The fork wires the multi-window
        // channel itself, so cross-window save still works.
        FlutterMultiWindowPlugin.setOnWindowCreatedCallback { controller in
            WindowManagerPlugin.register(
                with: controller.registrar(forPlugin: "WindowManagerPlugin"))
            ScreenRetrieverMacosPlugin.register(
                with: controller.registrar(forPlugin: "ScreenRetrieverMacosPlugin"))
        }

        super.awakeFromNib()
    }
    override public func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        super.order(place, relativeTo: otherWin)
        hiddenWindowAtLaunch()
    }
}
