
# WatchDeploymentManager (Swift)

## Overview

`WatchDeploymentManager` is a Swift-based command-line tool to automate building, installing, and retrying deployment of Apple Watch apps to physical devices. It handles device pairing, DDI initialization, robust retry logic, and detailed logging.

## Features

- All configuration is settable in Swift (see `WatchDeploymentConfig`)
- Robust retry logic for DDI and install steps
- Clean log management and error reporting
- No static references: everything is user-configurable

## Usage

1. Edit `watch-deployment-manager.swift` to set your deployment parameters in the `WatchDeploymentConfig` struct:

```swift
var config = WatchDeploymentConfig()
config.watchDeviceId = "WATCH_DEVICE_UDID"
config.workspacePath = "path/to/project.xcworkspace"
config.schemeName = "WatchAppScheme"
config.appName = "WatchApp"
config.uninstallBundleId = "com.example.watchapp"
// ...set other options as needed
let manager = WatchDeploymentManager(config: config)
manager.execute()
```

2. Run directly with Swift:

```sh
swift watch-deployment-manager.swift
```

Or compile and run:

```sh
swiftc watch-deployment-manager.swift -o watch-deployment-manager
./watch-deployment-manager
```

## Configuration Options

Set these fields in `WatchDeploymentConfig`:

| Field                | Description                                      |
|----------------------|--------------------------------------------------|
| watchDeviceId        | Device UDID for the target Apple Watch           |
| workspacePath        | Path to the .xcworkspace file                    |
| schemeName           | Xcode scheme name for the Watch app              |
| appName              | Name of the .app bundle (e.g., MyWatchApp)       |
| timeout              | Timeout for device operations (seconds)          |
| destinationTimeout   | Timeout for destination operations (seconds)     |
| shouldInstall        | true to run install step, false to skip          |
| shouldPrebuild       | true to prebuild the app, false to skip          |
| buildConfiguration   | Build configuration (e.g., Release, Debug)       |
| derivedDataPath      | Derived data folder for Xcode build              |
| ddiRetries           | Number of retries for DDI initialization         |
| installRetries       | Number of retries for app installation           |
| retrySleep           | Initial sleep between retries (seconds)          |
| maxRetrySleep        | Maximum sleep between retries (seconds)          |
| initialSettleSeconds | Initial settle time after transport restart      |
| ddiTimeout           | Timeout for DDI operations (seconds)             |
| uninstallBundleId    | Bundle ID to uninstall before install            |
| logDirectory         | Directory to store logs                          |

## Notes

- All logs are written to the directory specified by `logDirectory`.
- The tool will exit with an error if any critical step fails.
- Edit and run the Swift file directly for quick changes.
All paths and names are fully dynamic—no static references remain.
Designed for robust, repeatable watchOS app deployment in CI or local workflows.