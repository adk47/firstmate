# Mobile API Integration

## API Architecture

```
Pages/Screens
    │
    ▼
BLoCs (State Management)
    │
    ▼
Repositories (Data Abstraction)
    │
    ▼
MusoApi Client
    │
    ▼
HttpProvider (Dio)
    │
    ▼
Core Backend API (/api/m/v2)
```

## API Sections

| Section | Endpoints |
|---------|-----------|
| `authorization` | Login, signup, social auth, token refresh |
| `professionals` | Profile data, credits, collaborators |
| `analytics` | Stats, graphs, sources |
| `insights` | Charts, milestones |
| `workspace` | Team management, roster |
| `search` | Global search |
| `claiming` | Profile claiming flow |
| `feed` | Activity feed |

## MusoApi Client Pattern

```dart
// api/muso_api.dart
class MusoApi {
  final HttpProvider _http;
  
  late final AuthorizationApi authorization;
  late final ProfessionalsApi professionals;
  late final AnalyticsApi analytics;
  late final InsightsApi insights;
  late final WorkspaceApi workspace;
  late final SearchApi search;
  
  MusoApi(this._http) {
    authorization = AuthorizationApi(_http);
    professionals = ProfessionalsApi(_http);
    analytics = AnalyticsApi(_http);
    insights = InsightsApi(_http);
    workspace = WorkspaceApi(_http);
    search = SearchApi(_http);
  }
}
```

## Section API Pattern

```dart
// api/sections/professionals_api.dart
class ProfessionalsApi {
  final HttpProvider _http;
  
  ProfessionalsApi(this._http);
  
  Future<Profile> getProfile(String id) async {
    final response = await _http.get('/api/m/v2/professionals/$id');
    return Profile.fromJson(response.data['data']);
  }
  
  Future<List<Credit>> getCredits(String profileId) async {
    final response = await _http.get('/api/m/v2/professionals/$profileId/credits');
    return (response.data['data'] as List)
        .map((e) => Credit.fromJson(e))
        .toList();
  }
  
  Future<AnalyticsSummary> getStats(String profileId) async {
    final response = await _http.get('/api/m/v2/professionals/$profileId/stats');
    return AnalyticsSummary.fromJson(response.data['data']);
  }
}
```

## Repository Pattern

```dart
// repositories/profile_repository.dart
class ProfileRepository {
  final MusoApi _api;
  
  ProfileRepository(this._api);
  
  Future<Profile> getProfile(String id) async {
    try {
      return await _api.professionals.getProfile(id);
    } on DioException catch (e) {
      throw _mapError(e);
    }
  }
  
  Future<List<Credit>> getCredits(String profileId) async {
    return _api.professionals.getCredits(profileId);
  }
  
  ProfileException _mapError(DioException e) {
    if (e.response?.statusCode == 404) {
      return ProfileNotFoundException();
    }
    if (e.response?.statusCode == 403) {
      return ProfileAccessDeniedException();
    }
    return ProfileException(e.message ?? 'Unknown error');
  }
}
```

## Authentication Methods

| Method | Implementation |
|--------|----------------|
| Email/Password | `authorization.login(email, password)` |
| Facebook OAuth | `flutter_facebook_auth` + `authorization.socialLogin()` |
| Apple Sign-In | `sign_in_with_apple` + `authorization.socialLogin()` |
| Google Sign-In | `google_sign_in` + `authorization.socialLogin()` |

```dart
// Social auth flow
Future<AuthResult> signInWithGoogle() async {
  final googleUser = await GoogleSignIn().signIn();
  final auth = await googleUser?.authentication;
  
  return _api.authorization.socialLogin(
    provider: 'google',
    token: auth?.idToken,
  );
}
```

## Token Management

```dart
// Stored securely
final storage = FlutterSecureStorage();

// Save token
await storage.write(key: 'access_token', value: token);

// HttpProvider injects token
class HttpProvider {
  Future<Response> get(String path) async {
    final token = await storage.read(key: 'access_token');
    return _dio.get(
      path,
      options: Options(headers: {'Authorization': 'Bearer $token'}),
    );
  }
}
```
