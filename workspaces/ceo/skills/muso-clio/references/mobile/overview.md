# Mobile App Architecture

The **mobile** repo (`mobile`) contains the Flutter-based iOS and Android applications (in progress).

### Tech Stack

| Component | Technology |
|-----------|------------|
| Framework | Flutter 3.35.7+ |
| Language | Dart 3.9+ |
| State Management | flutter_bloc 9.1.1 + Freezed |
| Navigation | auto_route 10.3.0 |
| Networking | Dio 5.9 (via `network_utils`) |
| Code Gen | freezed, json_serializable, build_runner |
| UI Catalog | Widgetbook |

### Build & Configuration

- Run: `flutter run --dart-define-from-file=config.json`
- Version: `9.0.99+1` (from `pubspec.yaml`)
- SDK constraints: Dart `>=3.9.0 <4.0.0`, Flutter `>=3.35.7`

### Architecture

```text
Presentation layer
  Pages/Screens
  UI Widgets
  Theme system

State management (BLoC)
  Global BLoCs: AuthBloc, RosterBloc, AccDetailsBloc, InAppFeedBloc
  Feature BLoCs: SearchBloc, InsightsBloc, etc.

Data layer
  Repositories -> MusoApi client -> HttpProvider (Dio) -> core-backend (/api/m/v2)

Platform services
  DeepLinkService
  PushNotificationService
  IntercomService
  EventsTracking

Data flow
  Pages/Widgets -> BLoCs -> Repositories -> MusoApi -> HttpProvider -> core-backend
  Pages -> Platform services
```

### Project Structure

```
lib/
├── api/              # API clients (MusoApi, sectioned APIs)
├── repositories/     # Data abstraction layer
├── services/         # Platform services (push, deep links, etc.)
├── global/           # App-wide BLoCs, enums, usecases
├── modules/          # Feature modules (vertical slices)
│   ├── checklist/    # Onboarding checklist
│   ├── feed/         # Content feed
│   ├── insights/     # Performance insights
│   ├── plaques/      # Milestone plaques
│   ├── referrals/    # Referral program
│   ├── roster/       # Profile management
│   └── search/       # Global search
├── ui/
│   ├── pages/        # Screen widgets
│   ├── widgets/      # Reusable components
│   └── theme/        # App theming
├── utils/            # Navigation, extensions
├── initialization/   # App bootstrap & DI
└── localization/     # i18n (ARB files)
```

### Main Screens

| Screen | Description |
|--------|-------------|
| Home | Feed with For You/Popular tabs, search, notifications |
| Credits | Profile credits, submissions, recently added |
| Insights | Charts, milestones, track performance |
| Analytics | Graphs, sources, catalog analytics |
| Audit | Catalog audits, collaborators |
| Roster | Profile management, lists |
| Plaques | Milestone plaques ordering/customization |
| Menu | Account settings, workspace, billing |

### Global BLoCs

| BLoC | Purpose |
|------|---------|
| `AuthBloc` | Authentication state (login, signup, logout) |
| `AccDetailsBloc` | Account details and preferences |
| `RosterBloc` | User roster/profiles management |
| `InAppFeedBloc` | Knock notifications |
| `IntercomBloc` | Customer support integration |
| `TopAlbumsBloc` | Album data caching |
| `ChecklistProviderBloc` | Onboarding checklist state |

### API Integration

| API Section | Endpoints |
|-------------|-----------|
| `authorization` | Login, signup, social auth, token refresh |
| `professionals` | Profile data, credits, collaborators |
| `analytics` | Stats, graphs, sources |
| `insights` | Charts, milestones |
| `workspace` | Team management, roster |
| `search` | Global search |
| `claiming` | Profile claiming flow |
| `feed` | Activity feed |

### Authentication Methods

- Email/Password
- Facebook OAuth
- Apple Sign-In
- Google Sign-In

### Key Dependencies

| Package | Purpose |
|---------|---------|
| `flutter_bloc` | State management |
| `auto_route` | Declarative navigation |
| `dio` | HTTP client (via `network_utils`) |
| `freezed` + `json_serializable` | Immutable state classes + serialization |
| `knock_flutter` | In-app notifications |
| `intercom_flutter` | Customer support |
| `in_app_purchase` | Subscriptions |
| `flutter_secure_storage` | Token storage |
| `sign_in_with_apple`, `google_sign_in`, `flutter_facebook_auth` | Social auth |
| `widgetbook` | Component catalog |

### Workspace Packages (Monorepo)

| Package | Purpose |
|---------|---------|
| `muso_ui_kit` | UI components library |
| `muso_assets_kit` | Icons and assets |
| `domain_models` | Shared domain entities |
| `muso_notify` | Notification utilities |
| `muso_common` | Shared utilities |
| `network_utils` | HTTP/networking layer |
| `muso_styled_toast` | Toasts and in-app messaging |

### Custom Git Packages (Muso-AI/flutter_packages)

| Package | Purpose |
|---------|---------|
| `country_picker_service` | Country selection UI/service |
| `scharts_flutter_charts` | Chart widgets |
| `social_share` | Share integrations |
| `twitter_login` | X (Twitter) login |
| `knock_flutter` | In-app notifications |

### Platform Support

- **iOS**: App Store distribution, Apple Sign-In, StoreKit
- **Android**: Google Play distribution, Google Sign-In, Play Billing
- **macOS**: Secondary support available

---
