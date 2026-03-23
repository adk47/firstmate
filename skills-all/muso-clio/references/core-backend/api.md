# Core Backend API Reference

## API Versioning

| Route Prefix | Purpose | Auth | Used By |
|--------------|---------|------|---------|
| `/api/v4/` | Common v4 API (main) | JWT Token | Internal tools |
| `/api/c/v4` | Customer v4 API | Customer API Key | Partners |
| `/api/c/v4a` | Customer v4 Auth0 API | Auth0 Token | Partners |
| `/api/w/v2` | Web v2 API | JWT Token | web-credits |
| `/api/w/v3` | Web v3 API | JWT Token | web-credits |
| `/api/m/v2` | Mobile v2 API | JWT Token | mobile |
| `/api/m/v3` | Mobile v3 API | JWT Token | mobile |
| `/api/v3/` | Admin/internal API | JWT Token | Internal |
| `/api/i/` | Integration API (webhooks) | Various | External services |

## Authentication Flow

```
1. Client sends credentials to /login
2. Core Backend validates with Auth0
3. Auth0 returns token + user info
4. Core Backend finds/creates user in DB
5. Core Backend returns JWT + user data
6. Client includes JWT in Authorization header for subsequent requests
```

## Request Flow

```
Request
  --> TokenValidation middleware
  --> ACL middleware (role check)
  --> Guards (permission checks)
  --> Controller
  --> Service (business logic)
  --> Model (database)
  --> Response
```

## Common Endpoints

### User Endpoints
- `POST /api/w/v2/auth/login` - Login
- `POST /api/w/v2/auth/signup` - Register
- `GET /api/w/v2/user/profile` - Get current user
- `PUT /api/w/v2/user/profile` - Update profile

### Profile Endpoints
- `GET /api/v4/profile/:id` - Get profile
- `GET /api/v4/profile/:id/credits` - Get profile credits
- `GET /api/v4/profile/:id/stats` - Get profile stats
- `GET /api/v4/profile/:id/collaborators` - Get collaborators
- `POST /api/v4/profile/:id/claim` - Claim profile

### Workspace Endpoints
- `GET /api/w/v2/workspace` - Get current workspace
- `GET /api/w/v2/workspace/roster` - Get roster
- `POST /api/w/v2/workspace/roster` - Add to roster
- `GET /api/w/v2/workspace/members` - Get team members

### Analytics Endpoints
- `GET /api/v4/analytics/:profileId/summary` - Analytics summary
- `GET /api/v4/analytics/:profileId/trends` - Trend data
- `GET /api/v4/analytics/:profileId/milestones` - Milestones

### Search Endpoints
- `GET /api/v4/search` - Global search
- `GET /api/v4/search/profiles` - Search profiles
- `GET /api/v4/search/tracks` - Search tracks

## Customer API Flow

```
Partner Request (x-api-key header)
  --> API Gateway validates key
  --> Injects x-api-gw-auth header
  --> ALB routes to core-backend
  --> Core Backend validates x-api-gw-auth
  --> Response
```

## Response Format

All responses follow this structure:
```json
{
  "success": true,
  "data": { ... },
  "meta": {
    "pagination": { ... }
  }
}
```

Error responses:
```json
{
  "success": false,
  "error": {
    "code": "ERROR_CODE",
    "message": "Human readable message"
  }
}
```
