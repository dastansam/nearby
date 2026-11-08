import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  /// The mesh radio, alive as long as the app is.
  private var multipeer: Multipeer?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    let flutter = window?.rootViewController as! FlutterViewController
    multipeer = Multipeer(messenger: flutter.binaryMessenger)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
