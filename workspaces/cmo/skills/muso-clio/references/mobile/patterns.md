# Mobile Patterns

## BLoC Pattern

```dart
// modules/insights/bloc/insights_bloc.dart
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'insights_bloc.freezed.dart';

// Events
@freezed
class InsightsEvent with _$InsightsEvent {
  const factory InsightsEvent.load(String profileId) = _Load;
  const factory InsightsEvent.refresh() = _Refresh;
}

// State
@freezed
class InsightsState with _$InsightsState {
  const factory InsightsState.initial() = _Initial;
  const factory InsightsState.loading() = _Loading;
  const factory InsightsState.loaded(InsightsData data) = _Loaded;
  const factory InsightsState.error(String message) = _Error;
}

// BLoC
class InsightsBloc extends Bloc<InsightsEvent, InsightsState> {
  final InsightsRepository _repository;
  String? _currentProfileId;
  
  InsightsBloc(this._repository) : super(const InsightsState.initial()) {
    on<_Load>(_onLoad);
    on<_Refresh>(_onRefresh);
  }
  
  Future<void> _onLoad(_Load event, Emitter<InsightsState> emit) async {
    _currentProfileId = event.profileId;
    emit(const InsightsState.loading());
    
    try {
      final data = await _repository.getInsights(event.profileId);
      emit(InsightsState.loaded(data));
    } catch (e) {
      emit(InsightsState.error(e.toString()));
    }
  }
  
  Future<void> _onRefresh(_Refresh event, Emitter<InsightsState> emit) async {
    if (_currentProfileId == null) return;
    add(InsightsEvent.load(_currentProfileId!));
  }
}
```

## Screen Pattern

```dart
// ui/pages/insights/insights_page.dart
class InsightsPage extends StatelessWidget {
  final String profileId;
  
  const InsightsPage({required this.profileId});
  
  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) => InsightsBloc(context.read<InsightsRepository>())
        ..add(InsightsEvent.load(profileId)),
      child: const InsightsView(),
    );
  }
}

class InsightsView extends StatelessWidget {
  const InsightsView();
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Insights')),
      body: BlocBuilder<InsightsBloc, InsightsState>(
        builder: (context, state) {
          return state.when(
            initial: () => const SizedBox.shrink(),
            loading: () => const Center(child: CircularProgressIndicator()),
            loaded: (data) => InsightsContent(data: data),
            error: (message) => ErrorView(
              message: message,
              onRetry: () => context.read<InsightsBloc>().add(const InsightsEvent.refresh()),
            ),
          );
        },
      ),
    );
  }
}
```

## Navigation with auto_route

```dart
// utils/router.dart
@AutoRouterConfig()
class AppRouter extends $AppRouter {
  @override
  List<AutoRoute> get routes => [
    AutoRoute(page: HomeRoute.page, initial: true),
    AutoRoute(page: ProfileRoute.page, path: '/profile/:id'),
    AutoRoute(page: InsightsRoute.page, path: '/insights/:profileId'),
    AutoRoute(page: SettingsRoute.page, path: '/settings'),
  ];
}

// Navigate
context.router.push(ProfileRoute(id: profileId));
context.router.pushNamed('/profile/$profileId');

// Navigate and replace
context.router.replace(HomeRoute());

// Pop
context.router.pop();
```

## Freezed Model Pattern

```dart
// domain_models/lib/src/profile.dart
import 'package:freezed_annotation/freezed_annotation.dart';

part 'profile.freezed.dart';
part 'profile.g.dart';

@freezed
class Profile with _$Profile {
  const factory Profile({
    required String id,
    required String displayName,
    String? imageUrl,
    @Default([]) List<Credit> credits,
    @JsonKey(name: 'neptune_professional_id') String? neptuneId,
  }) = _Profile;
  
  factory Profile.fromJson(Map<String, dynamic> json) => _$ProfileFromJson(json);
}
```

## Repository Pattern

```dart
// repositories/insights_repository.dart
class InsightsRepository {
  final MusoApi _api;
  final CacheManager _cache;
  
  InsightsRepository(this._api, this._cache);
  
  Future<InsightsData> getInsights(String profileId) async {
    // Check cache first
    final cached = await _cache.get('insights_$profileId');
    if (cached != null && !cached.isExpired) {
      return InsightsData.fromJson(cached.data);
    }
    
    // Fetch from API
    final data = await _api.insights.getInsights(profileId);
    
    // Cache result
    await _cache.set('insights_$profileId', data.toJson(), ttl: Duration(minutes: 5));
    
    return data;
  }
}
```

## Widget Pattern

```dart
// ui/widgets/stats_card.dart
class StatsCard extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;
  final Color? color;
  
  const StatsCard({
    required this.title,
    required this.value,
    required this.icon,
    this.color,
  });
  
  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color ?? Theme.of(context).primaryColor),
                const SizedBox(width: 8),
                Text(title, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              value,
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
```

## Dependency Injection

```dart
// initialization/di.dart
void setupDependencies() {
  final getIt = GetIt.instance;
  
  // HTTP
  getIt.registerSingleton<HttpProvider>(HttpProvider());
  
  // API
  getIt.registerSingleton<MusoApi>(MusoApi(getIt<HttpProvider>()));
  
  // Repositories
  getIt.registerFactory<ProfileRepository>(
    () => ProfileRepository(getIt<MusoApi>()),
  );
  getIt.registerFactory<InsightsRepository>(
    () => InsightsRepository(getIt<MusoApi>(), getIt<CacheManager>()),
  );
  
  // Global BLoCs
  getIt.registerSingleton<AuthBloc>(AuthBloc(getIt<AuthRepository>()));
  getIt.registerSingleton<RosterBloc>(RosterBloc(getIt<RosterRepository>()));
}
```
