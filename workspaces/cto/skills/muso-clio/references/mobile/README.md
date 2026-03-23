# Mobile App (Flutter)

The Flutter-based iOS and Android applications for Muso.AI.

## Overview

| Attribute | Value |
|-----------|-------|
| **Repo** | `mobile` |
| **Framework** | Flutter 3.35.7+ |
| **Language** | Dart 3.9+ |
| **State** | flutter_bloc 9.1.1 + Freezed |
| **Navigation** | auto_route 10.3.0 |
| **Networking** | Dio 5.9 (via network_utils) |
| **Status** | In progress |

## When to Load

Load this reference when:
- Building or modifying screens/widgets
- Working with BLoC state management
- Implementing API integrations
- Working on navigation or routing
- Building platform-specific features (iOS/Android)

## Application Structure

```
lib/
├── api/              # API clients (MusoApi, sectioned APIs)
├── repositories/     # Data abstraction layer
├── services/         # Platform services (push, deep links)
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

## Main Screens

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

## Global BLoCs

| BLoC | Purpose |
|------|---------|
| `AuthBloc` | Authentication state (login, signup, logout) |
| `AccDetailsBloc` | Account details and preferences |
| `RosterBloc` | User roster/profiles management |
| `InAppFeedBloc` | Knock notifications |
| `IntercomBloc` | Customer support integration |
| `TopAlbumsBloc` | Album data caching |
| `ChecklistProviderBloc` | Onboarding checklist state |

## Build & Run

```bash
# Run with config
flutter run --dart-define-from-file=config.json

# Build iOS
flutter build ios --dart-define-from-file=config.json

# Build Android
flutter build apk --dart-define-from-file=config.json
```

## Related References

- `api.md` - API integration patterns
- `configuration.md` - Setup and environment
- `patterns.md` - BLoC and Flutter patterns
- `gotchas.md` - Platform-specific issues
