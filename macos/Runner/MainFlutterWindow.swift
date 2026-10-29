import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var lanPairPlatform: LanPairPlatform?
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    lanPairPlatform = LanPairPlatform(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}
