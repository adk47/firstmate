# Web Credits API Integration

## Service Layer

All API calls go through the service layer in `entities/*/service.ts`:

| Service | Purpose |
|---------|---------|
| `authService` | Login, signup, profile management |
| `analyticsService` | Analytics data |
| `creditsService` | Credits CRUD |
| `chartsService` | Music charts |
| `subscriptionService` | Billing/plans |
| `workspaceService` | Workspace management |
| `claimService` | Profile claiming |
| `feedService` | Activity feed |
| `pwsService` | Platform-wide stats |

## API Endpoints Used

### Auth
```typescript
// Login
POST /api/w/v2/auth/login
// Signup  
POST /api/w/v2/auth/signup
// Get current user
GET /api/w/v2/user/profile
```

### Profile
```typescript
// Get profile
GET /api/v4/profile/:id
// Get credits
GET /api/v4/profile/:id/credits
// Get stats
GET /api/v4/profile/:id/stats
// Get collaborators
GET /api/v4/profile/:id/collaborators
```

### Analytics
```typescript
// Summary
GET /api/v4/analytics/:profileId/summary
// Trends
GET /api/v4/analytics/:profileId/trends
// Milestones
GET /api/v4/analytics/:profileId/milestones
```

### Workspace
```typescript
// Get workspace
GET /api/w/v2/workspace
// Get roster
GET /api/w/v2/workspace/roster
// Add to roster
POST /api/w/v2/workspace/roster
```

## Axios Plugin

The axios plugin (`plugins/axios.plugin.ts`) handles:
- Base URL configuration
- JWT token injection
- Error interceptors
- Response transformation

```typescript
// plugins/axios.plugin.ts
export default function ({ $axios, store, redirect }) {
  $axios.onRequest((config) => {
    const token = store.state.auth.token;
    if (token) {
      config.headers.Authorization = `Bearer ${token}`;
    }
  });

  $axios.onError((error) => {
    if (error.response?.status === 401) {
      store.dispatch('auth/logout');
      redirect('/login');
    }
  });
}
```

## Service Pattern

```typescript
// entities/profile/service.ts
import { $axios } from '~/utils/api';

export const profileService = {
  async getById(id: string) {
    const response = await $axios.get(`/api/v4/profile/${id}`);
    return response.data.data;
  },

  async getCredits(id: string, params?: CreditsParams) {
    const response = await $axios.get(`/api/v4/profile/${id}/credits`, { params });
    return response.data;
  },

  async updateCredits(id: string, credits: Credit[]) {
    const response = await $axios.put(`/api/v4/profile/${id}/credits`, { credits });
    return response.data;
  },
};
```

## Error Handling

```typescript
// Wrap API calls with error handling
async function fetchProfile(id: string) {
  try {
    return await profileService.getById(id);
  } catch (error) {
    if (error.response?.status === 404) {
      throw new Error('Profile not found');
    }
    if (error.response?.status === 403) {
      throw new Error('Access denied');
    }
    throw error;
  }
}
```
