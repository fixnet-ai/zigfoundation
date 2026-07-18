import UIKit
import OSLog

// C functions from the Zig static library
@_silgen_name("runAllTests")
func runAllTests() -> Bool

@_silgen_name("getResultsBuf")
func getResultsBuf() -> UnsafePointer<CChar>

let logger = Logger(subsystem: "com.fixnet.zigfoundation", category: "test")

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        logger.info("zigfoundation iOS test app launched")

        window = UIWindow(frame: UIScreen.main.bounds)
        let vc = ViewController()
        window?.rootViewController = vc
        window?.makeKeyAndVisible()
        return true
    }
}

class ViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        logger.info("viewDidLoad: starting zigfoundation tests...")

        let passed = runAllTests()

        // 读取 Zig 端的结果缓冲区并通过 os.Logger 输出
        let resultStr = String(cString: getResultsBuf())
        logger.info("zigfoundation test results: \(resultStr, privacy: .public)")

        let label = UILabel()
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = .monospacedSystemFont(ofSize: 14, weight: .regular)

        if passed {
            label.text = "✅ zigfoundation\nAll 13 modules PASSED\n\nCheck: log show --predicate 'subsystem == \"com.fixnet.zigfoundation\"'"
            label.textColor = .systemGreen
            logger.info("zigfoundation: ALL TESTS PASSED")
        } else {
            label.text = "❌ zigfoundation\nSome tests FAILED\n\nCheck Console.app or log show"
            label.textColor = .systemRed
            logger.error("zigfoundation: SOME TESTS FAILED")
        }

        view.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
        ])
    }
}
