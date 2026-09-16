import UIKit
import WebKit

final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        guard
            let rawURL = ProcessInfo.processInfo.environment["GAMEALGO_E2E_URL"],
            let url = URL(string: rawURL)
        else {
            fatalError("GAMEALGO_E2E_URL is required")
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let viewController = UIViewController()
        viewController.view = webView

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = viewController
        window.makeKeyAndVisible()
        self.window = window

        webView.load(URLRequest(url: url))
        return true
    }
}

UIApplicationMain(
    CommandLine.argc,
    CommandLine.unsafeArgv,
    nil,
    NSStringFromClass(AppDelegate.self)
)
