import Foundation

struct WatchDeploymentConfig {
    var watchDeviceId: String = ""
    var workspacePath: String = ""
    var schemeName: String = ""
    var appName: String = ""
    var timeout: Int = 30
    var destinationTimeout: Int = 30
    var ddiTimeout: Int = 60
    var shouldInstall: Bool = true
    var shouldPrebuild: Bool = true
    var buildConfiguration: String = "Debug"
    var derivedDataPath: String = "./DerivedData"
    var ddiRetries: Int = 3
    var installRetries: Int = 3
    var retrySleep: Int = 2
    var maxRetrySleep: Int = 10
    var initialSettleSeconds: Int = 2
    var uninstallBundleId: String = ""
    var logDirectory: String = "./logs"
}

final class WatchDeploymentManager {
    private let config: WatchDeploymentConfig
    private let fileManager = FileManager.default

    private let timestamp: String
    private let ddiLogPath: String
    private let installLogPath: String
    private let buildLogPath: String
    private let pairLogPath: String

    init(config: WatchDeploymentConfig) {
        self.config = config

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        self.timestamp = formatter.string(from: Date())

        self.ddiLogPath = "\(config.logDirectory)/\(timestamp)-ddi.log"
        self.installLogPath = "\(config.logDirectory)/\(timestamp)-install.log"
        self.buildLogPath = "\(config.logDirectory)/\(timestamp)-build.log"
        self.pairLogPath = "\(config.logDirectory)/\(timestamp)-pair.log"

        createLogDirectoryIfNeeded()
    }

    func execute() {
        guard validateConfig() else {
            fputs("Invalid configuration.\n", stderr)
            exit(1)
        }

        guard buildWatchAppIfNeeded() else {
            fputs("Prebuild failed.\nBuild log: \(buildLogPath)\n", stderr)
            exit(1)
        }

        step("Restarting CoreDevice transport daemons")
        refreshTransport()
        sleepSeconds(config.initialSettleSeconds)

        step("Listing currently visible devices")
        _ = runCommand("/usr/bin/xcrun", [
            "devicectl",
            "list",
            "devices"
        ])

        step("Refreshing watch pairing")
        _ = runCommand("/usr/bin/xcrun", [
            "devicectl",
            "manage",
            "pair",
            "--device", config.watchDeviceId,
            "--timeout", "\(config.timeout)",
            "--log-output", pairLogPath
        ])
        sleepSeconds(config.initialSettleSeconds)

        guard initializeDDI() else {
            fputs(
                """
                DDI initialization did not succeed for the watch.
                Pair log: \(pairLogPath)
                DDI log: \(ddiLogPath)

                """,
                stderr
            )
            exit(1)
        }

        guard config.shouldInstall else {
            print("DDI initialization succeeded. Install step skipped.")
            return
        }

        uninstallWatchAppIfPresent()

        guard installWatchApp() else {
            fputs(
                """
                Install did not succeed.
                Build log: \(buildLogPath)
                Install log: \(installLogPath)

                """,
                stderr
            )
            exit(1)
        }

        print("""
        Watch retry sequence completed successfully.
        Install log: \(installLogPath)
        """)
    }

    private func validateConfig() -> Bool {
        return !config.watchDeviceId.isEmpty &&
               !config.workspacePath.isEmpty &&
               !config.schemeName.isEmpty &&
               !config.appName.isEmpty &&
               !config.buildConfiguration.isEmpty &&
               !config.derivedDataPath.isEmpty &&
               !config.logDirectory.isEmpty
    }

    private func createLogDirectoryIfNeeded() {
        do {
            try fileManager.createDirectory(
                atPath: config.logDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            fputs("Failed to create log directory: \(error)\n", stderr)
        }
    }

    private func step(_ message: String) {
        print("\n==> \(message)")
    }

    @discardableResult
    private func runCommand(
        _ executablePath: String,
        _ arguments: [String],
        logTo logPath: String? = nil
    ) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

            if let stdoutText = String(data: stdoutData, encoding: .utf8), !stdoutText.isEmpty {
                print(stdoutText, terminator: "")
            }

            if let stderrText = String(data: stderrData, encoding: .utf8), !stderrText.isEmpty {
                fputs(stderrText, stderr)
            }

            if let logPath {
                appendToLogFile(path: logPath, data: stdoutData)
                appendToLogFile(path: logPath, data: stderrData)
            }

            return process.terminationStatus == 0
        } catch {
            fputs("Failed to run command \(executablePath): \(error)\n", stderr)
            return false
        }
    }

    private func appendToLogFile(path: String, data: Data) {
        guard !data.isEmpty else { return }

        if !fileManager.fileExists(atPath: path) {
            fileManager.createFile(atPath: path, contents: nil)
        }

        do {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            fputs("Failed to write log file at \(path): \(error)\n", stderr)
        }
    }

    private func refreshTransport() {
        let userId = getuid()

        _ = runCommand("/bin/launchctl", [
            "kickstart",
            "-k",
            "user/\(userId)/com.apple.CoreDevice.CoreDeviceService"
        ])

        _ = runCommand("/bin/launchctl", [
            "kickstart",
            "-k",
            "user/\(userId)/com.apple.CoreDevice.remotepairingd"
        ])

        sleepSeconds(1)
    }

    private func sleepWithBackoff(attempt: Int) {
        let exponentialDelay = config.retrySleep * Int(pow(2.0, Double(attempt - 1)))
        let delay = min(exponentialDelay, config.maxRetrySleep)
        sleepSeconds(delay)
    }

    private func sleepSeconds(_ seconds: Int) {
        sleep(UInt32(seconds))
    }

    private func buildWatchAppIfNeeded() -> Bool {
        guard config.shouldPrebuild else {
            return true
        }

        step("Prebuilding watch app")

        let didBuild = runCommand(
            "/usr/bin/xcodebuild",
            [
                "-workspace", config.workspacePath,
                "-scheme", config.schemeName,
                "-configuration", config.buildConfiguration,
                "-destination", "generic/platform=watchOS",
                "-derivedDataPath", config.derivedDataPath,
                "build"
            ],
            logTo: buildLogPath
        )

        guard didBuild else {
            return false
        }

        let appPath = watchAppPath()
        guard fileManager.fileExists(atPath: appPath) else {
            fputs("Prebuild completed but watch app was not found at \(appPath)\n", stderr)
            return false
        }

        return true
    }

    private func initializeDDI() -> Bool {
        for attempt in 1...config.ddiRetries {
            step("Trying to initialize watch DDI services (attempt \(attempt)/\(config.ddiRetries))")

            let didInitialize = runCommand(
                "/usr/bin/xcrun",
                [
                    "devicectl",
                    "--timeout", "\(config.ddiTimeout)",
                    "device",
                    "info",
                    "ddiServices",
                    "--device", config.watchDeviceId,
                    "--log-output", ddiLogPath
                ],
                logTo: ddiLogPath
            )

            if didInitialize {
                return true
            }

            if attempt < config.ddiRetries {
                print("DDI attempt \(attempt) failed. Refreshing transport and retrying.")
                refreshTransport()

                _ = runCommand(
                    "/usr/bin/xcrun",
                    [
                        "devicectl",
                        "manage",
                        "pair",
                        "--device", config.watchDeviceId,
                        "--timeout", "\(config.timeout)",
                        "--log-output", pairLogPath
                    ],
                    logTo: pairLogPath
                )

                sleepWithBackoff(attempt: attempt)
            }
        }

        return false
    }

    private func uninstallWatchAppIfPresent() {
        guard !config.uninstallBundleId.isEmpty else {
            return
        }

        step("Removing the existing watch app if present")

        _ = runCommand(
            "/usr/bin/xcrun",
            [
                "devicectl",
                "--timeout", "\(config.ddiTimeout)",
                "device",
                "uninstall",
                "app",
                "--device", config.watchDeviceId,
                config.uninstallBundleId,
                "--log-output", installLogPath
            ],
            logTo: installLogPath
        )
    }

    private func installWatchApp() -> Bool {
        let appPath = watchAppPath()

        for attempt in 1...config.installRetries {
            step("Installing the prebuilt watch app (attempt \(attempt)/\(config.installRetries))")

            let didInstall = runCommand(
                "/usr/bin/xcrun",
                [
                    "devicectl",
                    "--timeout", "\(config.ddiTimeout)",
                    "device",
                    "install",
                    "app",
                    "--device", config.watchDeviceId,
                    appPath,
                    "--log-output", installLogPath
                ],
                logTo: installLogPath
            )

            if didInstall {
                return true
            }

            if attempt < config.installRetries {
                print("Install attempt \(attempt) failed. Reinitializing DDI and retrying.")
                refreshTransport()
                sleepWithBackoff(attempt: attempt)

                guard initializeDDI() else {
                    return false
                }
            }
        }

        return false
    }

    private func watchAppPath() -> String {
        "\(config.derivedDataPath)/Build/Products/\(config.buildConfiguration)-watchos/\(config.appName).app"
    }
}

// Example usage
var config = WatchDeploymentConfig()
config.watchDeviceId = "WATCH_DEVICE_UDID"
config.workspacePath = "path/to/project.xcworkspace"
config.schemeName = "WatchAppScheme"
config.appName = "WatchApp"
config.uninstallBundleId = "com.example.watchapp"

let manager = WatchDeploymentManager(config: config)
manager.execute()