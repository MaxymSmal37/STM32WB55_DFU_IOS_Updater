# STM32WB55 OTA Updater

An iOS app for finding STM32WB55 devices over Bluetooth Low Energy (BLE), inspecting device and connection information, and transferring firmware over the air.

## Features

- Scan for nearby supported devices and connect over BLE.
- View the device firmware version, wireless firmware information, serial number, and hardware revision.
- Inspect BLE services, OTA characteristics, notification state, and link write limits.
- Import a firmware image (`.bin` or another data file) and view its size and SHA-256 fingerprint.
- Erase flash and transfer firmware in acknowledged batches, with progress, transfer speed, and estimated time remaining.
- Select automatic, full 128-byte, or manual batch sizing based on the BLE link.
- View updater and BLE diagnostic logs.
- See the updater's app version on the Bluetooth screen.

## Requirements

- Xcode with the iOS SDK.
- An iPhone or iPad running iOS 18.6 or later.
- A compatible STM32WB55 device running firmware that implements this app's BLE OTA protocol.

## Build and run

1. Open `STM32WB55_OTA_Updater.xcodeproj` in Xcode.
2. Select the `STM32WB55_OTA_Updater` scheme and an iPhone or iPad destination.
3. Configure signing for your development team, then build and run the app.
4. Allow Bluetooth access when prompted.

To run the test scheme from the command line:

```sh
xcodebuild test \
  -project STM32WB55_OTA_Updater.xcodeproj \
  -scheme STM32WB55_OTA_Updater \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

Change the simulator name to one installed with your Xcode version.

## Use

1. Tap **Scan** and select the target device.
2. Confirm that the device is connected and the OTA characteristics are ready.
3. Tap **Choose File** and select the firmware image supplied for the device.
4. Choose a batch mode. **Auto** uses the largest payload supported by the BLE link. **Require 128** waits for a link that supports the full payload. **Manual** lets you select a smaller payload.
5. Tap **Update** and confirm. Keep the app in the foreground and do not disconnect or close it until the update completes.

An interrupted update may leave the device requiring recovery. Use only firmware intended for the target device.

## BLE compatibility

The app expects the device's OTA services and characteristics to match the UUIDs and frame formats defined in `STM32WB55_OTA_Updater/BLEConstants.swift` and `STM32WB55_OTA_Updater/OTAProtocol.swift`. The bootloader must support the corresponding erase, transfer, and status-notification behavior. The app's connection diagnostics can help identify missing characteristics or a link that cannot support the selected batch size.

## Versioning

The app version is set by `MARKETING_VERSION` in the Xcode project; the build number is set by `CURRENT_PROJECT_VERSION`. Release notes are tracked in [CHANGELOG.md](CHANGELOG.md).
