import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var mediaBridge: NativeMediaBridge?
  private var licenseBridge: ZlarpLicenseBridge?
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    licenseBridge = ZlarpLicenseBridge(messenger: engineBridge.applicationRegistrar.messenger())
    mediaBridge = NativeMediaBridge(messenger: engineBridge.applicationRegistrar.messenger())
  }
}
