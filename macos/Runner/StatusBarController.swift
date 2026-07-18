import AppKit
import Cocoa
import FlutterMacOS
import WebKit

class PopoverContainerViewController: NSViewController {
    let flutterViewController: FlutterViewController
    
    init(flutterViewController: FlutterViewController) {
        self.flutterViewController = flutterViewController
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func loadView() {
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 375, height: 600))
                
        addChild(flutterViewController)
        flutterViewController.view.frame = self.view.bounds
        flutterViewController.view.autoresizingMask = [.width, .height]
        self.view.addSubview(flutterViewController.view)
    }
}

class StatusBarController {
    private var statusBar: NSStatusBar
    private var statusItem: NSStatusItem
    private var popover: NSPopover
    private var contextMenu: NSMenu?
    
    init(_ popover: NSPopover) {
        self.popover = popover
        statusBar = NSStatusBar.system
        statusItem = statusBar.statusItem(withLength: NSStatusItem.squareLength)
        
        
        if let statusBarButton = statusItem.button {
            
            if let icon = NSImage(systemSymbolName: "xmark.rectangle", accessibilityDescription: "FlClashM") {
                let config = NSImage.SymbolConfiguration(scale: .large)
                let configuredIcon = icon.withSymbolConfiguration(config)
                statusBarButton.image = configuredIcon
                statusBarButton.image?.isTemplate = true
            }
            
            statusBarButton.action = #selector(togglePopover(sender:))
            statusBarButton.target = self
            
            statusBarButton.sendAction(on: [.leftMouseUp, .rightMouseUp])
        } else {
            NSLog("StatusBarController: ERROR - Could not get status bar button!")
        }
        
        setupContextMenu()
    }
    
    private func setupContextMenu() {
        let menu = NSMenu()
        
        let quitItem = NSMenuItem(
            title: "Quit FlClashM",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
        
        contextMenu = menu
        NSLog("StatusBarController: Context menu created")
    }
    
    @objc func togglePopover(sender: AnyObject) {
        if let event = NSApp.currentEvent {
            if event.type == .rightMouseUp {
                showContextMenu()
                return
            }
        }
        
        if(popover.isShown) {
            hidePopover(sender)
        }
        else {
            showPopover(sender)
        }
    }
    
    private func showContextMenu() {
        if let menu = contextMenu, let button = statusItem.button {
            statusItem.menu = menu
            button.performClick(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.statusItem.menu = nil
            }
        }
    }
    
    @objc func quitApp() {
        NSLog("StatusBarController: Quit requested")
        NSApplication.shared.terminate(nil)
    }
    
    func showPopover(_ sender: AnyObject) {
        if let statusBarButton = statusItem.button {
            popover.show(relativeTo: statusBarButton.bounds, of: statusBarButton, preferredEdge: NSRectEdge.maxY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
    
    func hidePopover(_ sender: AnyObject) {
        popover.performClose(sender)
    }
    
    func updateIcon(isVpnConnected: Bool) {
        if let button = statusItem.button {
            let imageName = isVpnConnected ? "checkmark.rectangle.fill" : "xmark.rectangle"
            if let icon = NSImage(systemSymbolName: imageName, accessibilityDescription: "FlClashM") {
                let config = NSImage.SymbolConfiguration(scale: .large)
                let configuredIcon = icon.withSymbolConfiguration(config)
                button.image = configuredIcon
                button.image?.isTemplate = true
            }
        }
    }


}

/// A standalone window hosting a native WKWebView, used on macOS to show
/// zashboard outside the tray popover. The popover mis-maps platform-view
/// pointer input (every click lands offset), so an in-Flutter webview there is
/// unusable; a plain WKWebView in a real NSWindow has none of that and gives the
/// dashboard proper space. The app is `LSUIElement` (accessory), so it is
/// promoted to `.regular` while the window is open and dropped back to
/// `.accessory` on close, so the window focuses and shows in Cmd-Tab normally.
class ZashboardWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var webView: WKWebView?
    private let onClosed: () -> Void

    init(onClosed: @escaping () -> Void) {
        self.onClosed = onClosed
        super.init()
    }

    func show(urlString: String) {
        guard let url = URL(string: urlString) else { return }

        NSApp.setActivationPolicy(.regular)

        if window == nil {
            let rect = NSRect(x: 0, y: 0, width: 1100, height: 720)
            let w = NSWindow(
                contentRect: rect,
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            w.title = "zashboard"
            w.center()
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 640, height: 480)
            w.delegate = self

            let wv = WKWebView(frame: rect, configuration: WKWebViewConfiguration())
            wv.autoresizingMask = [.width, .height]
            w.contentView = wv

            window = w
            webView = wv
        }

        webView?.load(URLRequest(url: url))
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Fully tear down the WKWebView so its helper processes (the "about:"
        // WebContent, "Graphics and media", "Networking") terminate instead of
        // lingering in memory — reusing it kept them alive. show() recreates the
        // window and web view on the next open.
        webView?.stopLoading()
        window?.contentView = nil
        webView = nil
        window?.delegate = nil
        window = nil
        onClosed()
    }
}
