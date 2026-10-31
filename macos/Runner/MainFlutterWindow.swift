import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var lanPairPlatform: LanPairPlatform?
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    // AppKit stores the frame in the app's own preferences and restores it
    // here, so the size and position survive quitting and relaunching.
    self.setFrameAutosaveName("LANPairMainWindow")

    RegisterGeneratedPlugins(registry: flutterViewController)
    lanPairPlatform = LanPairPlatform(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}
