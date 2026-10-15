import Flutter
import UIKit

/// Deliberately separate from media_v1: no media, filenames or GPS cross this channel.
@MainActor
final class ZlarpLicenseBridge {
    private let channel: FlutterMethodChannel

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: "com.vxtiglitch.metadataeditor/license_v1", binaryMessenger: messenger)
        channel.setMethodCallHandler { call, result in
            let service = ZlarpLicenseService.shared
            switch call.method {
            case "status": result(service.status)
            case "refresh":
                var key: String?
                if let raw = call.arguments {
                    guard let args = raw as? [String: Any], Set(args.keys) == ["key"],
                          let entered = args["key"] as? String, entered.utf8.count <= 256 else {
                        result(FlutterError(code: "invalid_argument", message: "Enter a valid Zlarp license key.", details: nil))
                        return
                    }
                    key = entered
                }
                Task { result(await service.refresh(key: key)) }
            case "clear": result(service.clear())
            default: result(FlutterMethodNotImplemented)
            }
        }
    }
}
