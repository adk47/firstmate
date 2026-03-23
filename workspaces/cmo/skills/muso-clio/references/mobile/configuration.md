# Mobile Configuration

## Environment Setup

### Prerequisites
- Flutter 3.35.7+
- Dart SDK 3.9+
- Xcode 15+ (for iOS)
- Android Studio (for Android)
- CocoaPods (for iOS)

### Local Development

1. Clone the repository:
```bash
cd mobile
```

2. Get dependencies:
```bash
flutter pub get
```

3. Generate code (Freezed, JSON serialization):
```bash
flutter pub run build_runner build --delete-conflicting-outputs
```

4. Create config file:
```bash
cp config.example.json config.json
```

5. Run the app:
```bash
flutter run --dart-define-from-file=config.json
```

## Configuration File

```json
// config.json
{
  "API_URL": "https://api.muso.ai",
  "AUTH0_DOMAIN": "<tenant>.auth0.com",
  "AUTH0_CLIENT_ID": "<client-id>",
  "AMPLITUDE_API_KEY": "<key>",
  "INTERCOM_APP_ID": "<app-id>",
  "KNOCK_PUBLIC_KEY": "<key>",
  "ENVIRONMENT": "development"
}
```

## SDK Constraints

```yaml
# pubspec.yaml
environment:
  sdk: ">=3.9.0 <4.0.0"
  flutter: ">=3.35.7"
```

## Key Dependencies

| Package | Purpose |
|---------|---------|
| `flutter_bloc` | State management |
| `auto_route` | Declarative navigation |
| `dio` | HTTP client (via network_utils) |
| `freezed` + `json_serializable` | Immutable classes + serialization |
| `knock_flutter` | In-app notifications |
| `intercom_flutter` | Customer support |
| `in_app_purchase` | Subscriptions |
| `flutter_secure_storage` | Token storage |
| `sign_in_with_apple` | Apple Sign-In |
| `google_sign_in` | Google Sign-In |
| `flutter_facebook_auth` | Facebook auth |
| `widgetbook` | Component catalog |

## Workspace Packages (Monorepo)

| Package | Purpose |
|---------|---------|
| `muso_ui_kit` | UI components library |
| `muso_assets_kit` | Icons and assets |
| `domain_models` | Shared domain entities |
| `muso_notify` | Notification utilities |
| `muso_common` | Shared utilities |
| `network_utils` | HTTP/networking layer |
| `muso_styled_toast` | Toasts and in-app messaging |

## Code Generation

```bash
# Generate once
flutter pub run build_runner build --delete-conflicting-outputs

# Watch mode (regenerate on change)
flutter pub run build_runner watch --delete-conflicting-outputs
```

## Build Commands

```bash
# Development
flutter run --dart-define-from-file=config.json

# iOS Release
flutter build ios --release --dart-define-from-file=config.json

# Android APK
flutter build apk --release --dart-define-from-file=config.json

# Android App Bundle (Play Store)
flutter build appbundle --release --dart-define-from-file=config.json
```

## iOS Setup

1. Install CocoaPods:
```bash
cd ios && pod install
```

2. Open in Xcode:
```bash
open ios/Runner.xcworkspace
```

3. Configure signing in Xcode

## Android Setup

1. Configure `android/local.properties`:
```properties
sdk.dir=/Users/<user>/Library/Android/sdk
flutter.sdk=/Users/<user>/flutter
```

2. Configure signing in `android/app/build.gradle`

## Testing

```bash
# Unit tests
flutter test

# Integration tests
flutter test integration_test/

# With coverage
flutter test --coverage
```

## Widgetbook (Component Catalog)

```bash
# Run Widgetbook
flutter run -t lib/widgetbook.dart
```
