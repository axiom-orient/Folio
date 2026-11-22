# Mac application composition

The default Mac app builds from this repository without a SEMI SDK. SEMI connection is omitted and the app does not show the SEMI connection control. The package is not a dependency of the root SwiftPM SDK.

From the repository root, after installing Git LFS and fetching the model files:

```sh
git lfs pull
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift build --package-path MacApp --scratch-path /tmp/FolioMacBuild --product FolioMac
```

`script/build_and_run.sh` uses this package and stages the local app bundle outside the checkout. The iCloud/App Group application and extensions are configured in `Folio.xcodeproj`; signing them requires your own Apple development team and capabilities.

To include the optional existing SEMI adapter, set `FOLIO_SEMI_SDK_PATH` to the absolute path of a compatible `SEMIProviderSDK` package **before** resolving packages and building:

```sh
export FOLIO_SEMI_SDK_PATH=/absolute/path/to/SEMIProviderSDK
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift build --package-path MacApp --scratch-path /tmp/FolioMacSEMI --product FolioMac
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift test --package-path MacIntegration --scratch-path /tmp/FolioSEMITests
```

The same variable must be present when launching Xcode or `xcodebuild`, because Xcode resolves the local `MacIntegration` manifest. Use a separate scratch/derived-data directory when switching configurations; restart Xcode and resolve packages again if needed. An invalid nonempty path causes package resolution to fail rather than silently disabling integration. The separate SEMI SDK and its license are not included in this repository.
