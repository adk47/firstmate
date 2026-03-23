# Mobile Gotchas

## Code Generation Required

After modifying Freezed classes or adding JSON serialization:

```bash
# MUST run this or app won't compile
flutter pub run build_runner build --delete-conflicting-outputs
```

Common symptoms when you forget:
- `_$ProfileFromJson` undefined
- `_$InsightsState` undefined
- Part file errors

## Freezed Union Pattern

```dart
// WRONG - forgetting .when() exists
if (state is _Loading) { ... }
if (state is _Loaded) { ... }

// CORRECT - use the generated methods
state.when(
  initial: () => ...,
  loading: () => ...,
  loaded: (data) => ...,
  error: (msg) => ...,
);

// Or for partial handling
state.maybeWhen(
  loaded: (data) => handleLoaded(data),
  orElse: () => null,
);
```

## BLoC Memory Leaks

```dart
// WRONG - BLoC created inline, not disposed
BlocProvider(
  create: (_) => InsightsBloc(repo)..add(Load()),
  child: ...,
);
// This leaks if widget is removed from tree without proper disposal

// CORRECT - use lazy: false or ensure disposal
BlocProvider(
  create: (_) => InsightsBloc(repo)..add(Load()),
  lazy: false, // Creates immediately
  child: ...,
);

// Or access existing BLoC
BlocProvider.value(
  value: existingBloc,
  child: ...,
);
```

## Context Access After Async

```dart
// WRONG - context might be invalid after await
Future<void> _onButtonPressed() async {
  await doSomethingAsync();
  Navigator.of(context).pop(); // Context might be disposed!
}

// CORRECT - check mounted
Future<void> _onButtonPressed() async {
  await doSomethingAsync();
  if (mounted) {
    Navigator.of(context).pop();
  }
}

// Or use auto_route which handles this
Future<void> _onButtonPressed() async {
  await doSomethingAsync();
  if (context.mounted) {
    context.router.pop();
  }
}
```

## Platform-Specific Auth

```dart
// Apple Sign-In only available on iOS/macOS
if (Platform.isIOS || Platform.isMacOS) {
  // Show Apple Sign-In button
}

// Google Sign-In configuration differs
// iOS: GoogleService-Info.plist
// Android: google-services.json
```

## Secure Storage Limitations

```dart
// On Android, secure storage is cleared on app uninstall
// On iOS, keychain persists across reinstalls (sometimes unexpected)

// For logout, explicitly clear
await FlutterSecureStorage().deleteAll();
```

## Dio Exception Handling

```dart
// WRONG - catching generic Exception loses info
try {
  await api.get('/endpoint');
} catch (e) {
  print(e); // Just "DioException"
}

// CORRECT - handle DioException specifically
try {
  await api.get('/endpoint');
} on DioException catch (e) {
  if (e.type == DioExceptionType.connectionTimeout) {
    // Handle timeout
  }
  if (e.response?.statusCode == 401) {
    // Handle auth error
  }
  // Access response body
  final errorData = e.response?.data;
}
```

## Image Caching

```dart
// Network images should use cached_network_image
CachedNetworkImage(
  imageUrl: profile.imageUrl,
  placeholder: (context, url) => CircularProgressIndicator(),
  errorWidget: (context, url, error) => Icon(Icons.person),
);

// NOT this (no caching, re-downloads every time)
Image.network(profile.imageUrl);
```

## List Performance

```dart
// WRONG - builds all items immediately
ListView(
  children: items.map((item) => ItemWidget(item)).toList(),
);

// CORRECT - builds items lazily as they scroll into view
ListView.builder(
  itemCount: items.length,
  itemBuilder: (context, index) => ItemWidget(items[index]),
);
```

## JSON Key Naming

Backend uses snake_case, Dart uses camelCase:

```dart
@freezed
class Profile with _$Profile {
  const factory Profile({
    required String id,
    @JsonKey(name: 'display_name') required String displayName,
    @JsonKey(name: 'image_url') String? imageUrl,
    @JsonKey(name: 'neptune_professional_id') String? neptuneId,
  }) = _Profile;
}
```

## Null Safety with API Responses

```dart
// API might return null for optional fields
// Always handle nullability

// WRONG
final name = json['display_name'] as String; // Crash if null

// CORRECT
final name = json['display_name'] as String? ?? 'Unknown';

// Or in Freezed
@Default('Unknown') String displayName,
```

## Hot Reload Limitations

Hot reload doesn't work for:
- Changes to `main.dart`
- Changes to native code (iOS/Android)
- Changes to Freezed classes (need build_runner)
- Adding new assets

Use hot restart (`Shift+R`) for these cases.

## In-App Purchase Testing

```dart
// Test purchases only work on:
// - iOS: Physical device with sandbox account
// - Android: Internal testing track or licensed testers

// Emulators/simulators won't process purchases
```
