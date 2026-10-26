import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if let folder = try? exportFolder() {
      // Only our temporary share-sheet files; never remove a user-saved Files copy.
      for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
        try? FileManager.default.removeItem(at: file)
      }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(name: "app.familycompass/activity", binaryMessenger: engineBridge.applicationRegistrar.messenger())
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "exportText" else { result(FlutterMethodNotImplemented); return }
      guard let self = self, let args = call.arguments as? [String: Any],
            let name = args["name"] as? String, let text = args["text"] as? String,
            name.range(of: "^[A-Za-z0-9_-]+\\.txt$", options: .regularExpression) != nil,
            name.count <= 100, let data = text.data(using: .utf8), data.count <= 8_000_000 else {
        result(FlutterError(code: "export", message: "Invalid report.", details: nil)); return
      }
      do {
        let file = try self.exportFolder().appendingPathComponent(name)
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excludedFile = file
        try excludedFile.setResourceValues(values)
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
              var controller = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
          try? FileManager.default.removeItem(at: file)
          result(FlutterError(code: "export", message: "Open the app to export.", details: nil)); return
        }
        while let presented = controller.presentedViewController { controller = presented }
        let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        if let popover = sheet.popoverPresentationController {
          popover.sourceView = controller.view
          popover.sourceRect = CGRect(x: controller.view.bounds.midX, y: controller.view.bounds.midY, width: 1, height: 1)
          popover.permittedArrowDirections = []
        }
        sheet.completionWithItemsHandler = { _, _, _, error in
          try? FileManager.default.removeItem(at: file)
          if error != nil { result(FlutterError(code: "export", message: "Could not export the report.", details: nil)) }
          else { result(nil) }
        }
        controller.present(sheet, animated: true)
      } catch {
        result(FlutterError(code: "export", message: "Could not prepare the report.", details: nil))
      }
    }
  }

  private func exportFolder() throws -> URL {
    let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("FamilyCompassExports", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }
}
