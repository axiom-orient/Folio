# Mac application composition

This package composes the existing Folio application with the optional SEMI adapter. It is a development application package and is not a dependency of the root SwiftPM SDK.

From the repository root:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift build --package-path MacApp --scratch-path /tmp/FolioMacBuild --product FolioMac
```

The normal `script/build_and_run.sh` entry point uses this package automatically and stages the app bundle outside the checkout. The signed iCloud/App Group application and extensions remain configured in `Folio.xcodeproj`.

`FOLIO_SEMI_SDK_PATH` selects the local SEMIProviderSDK checkout for this development adapter. This app-only setting is not required by `FolioCore` or `FolioSDKUI` consumers.
