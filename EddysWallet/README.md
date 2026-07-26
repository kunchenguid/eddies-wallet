# Native app

`EddysWallet.xcodeproj` is a SwiftUI iOS/iPadOS app targeting iOS 17 and device families 1 and 2. The UI uses adaptive `horizontalSizeClass` layouts and native sheets, forms, navigation, Dynamic Type-friendly system fonts, and accessibility labels.

## Local development

```sh
xcodebuild -project EddysWallet.xcodeproj -scheme EddysWallet \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' test
```

The app starts with fixture data after the local Sign in with Apple integration point. The fixture parent PIN is `1234` for the role-gate test path. No network call or private backend is used.

`WalletRepository` is the boundary for a future authoritative API. `MockWalletRepository` is the only current implementation and keeps accepted balance, pending commands, rejected commands, stale time, and loan rules local to the fixture.
