# Security & Authentication

## Authentication Methods

| Method | Used By | Mechanism |
|--------|---------|-----------|
| JWT Token | Web/Mobile apps | Auth0 + custom JWT |
| API Key | Customer API | API Gateway + secret header |
| OAuth | Social login | Auth0 with Facebook/Google/Apple |

## Multi-Provider Authentication

### Primary: Auth0 (v4a routes)
- JWT validation via `x-api-gw-user-uuid` header
- Management API for user CRUD operations
- JWKS validation

### Internal JWT (Legacy v2-v3)
- Token validation middleware (`tokenValidation.js`)
- Signed with app secret
- Contains: userId, email, roles, profileId

### Social Login Providers
- Apple Sign-In (`appleUserId`)
- Facebook (`facebookUserId`)
- Google (`googleUserId`)

## Authorization Model

```text
Request
  -> TokenValidation
  -> ACL (role check)
  -> Guards system
      - Workspace access
      - Subscription check
      - Claiming permission
      - Admin/owner role
  -> Controller
```

## Guard Functions

Located in `src/components/guards/` (core-backend):

| Guard | Purpose |
|-------|---------|
| `workspaceAccess.guard.js` | Workspace membership verification |
| `subscription.guard.js` | Active subscription required |
| `businessSubscription.guard.js` | Business tier required |
| `proSeat.guard.js` | Pro seat access |
| `seatAccess.guard.js` | Specific seat permissions |
| `listAccess.guard.js` | List viewing permissions |
| `claiming.guard.js` | Profile claiming rights |
| `userAdminRole.guard.js` | Admin role check |
| `userOwnerRole.guard.js` | Owner role check |

## Security Boundaries

| Boundary | Purpose |
|----------|---------|
| **WAF** | Protects CloudFront distributions |
| **Security Groups** | Restrict traffic between tiers |
| **VPC Endpoints** | Keep AWS service traffic private |
| **IAM Roles** | ECS task roles, EKS IRSA |
| **Secrets Manager / SSM** | Store DB passwords, API keys |
| **KMS** | Encrypt secrets, RDS, Redis at rest |
| **MongoDB Atlas VPC Peering** | Private connectivity |

## Scraping Protection (Amazon WAF)

Source: KT meeting 2026-01-28

### Web Frontend (web-credits)
Protected by Amazon WAF with custom rule sets:
- **GA4 Fingerprint Rate Limiting**: Combines user agent + IP address using an open-source algorithm to generate a unique token
- More effective than IP-only rate limiting (blocks sophisticated scrapers that rotate IPs)
- Scraping is a constant issue requiring ongoing tuning

### Core Backend API
- **Minimal bot protection** - high risk of blocking legitimate mobile/service requests
- Relies on auth rather than WAF rules

### Industry Data Processing API
- **Internal only** - not public-facing
- Only accessible via `corend` (core-backend)
- No WAF needed (VPC-internal traffic)

## Secrets Management

### AWS SSM Parameter Store
- Path pattern: `/app/<service>/<env>/<param>`
- Example: `/app/core-backend/dev/db/password`
- SecureString type with KMS encryption

### AWS Secrets Manager
- Database credentials (auto-managed by RDS)
- Service-specific secrets

### Kubernetes Secrets
- Created via Terraform `kubernetes_secret` resources
- Contains DB credentials, SQS URLs, service configuration

## Web Frontend Auth (web-credits)

### Auth Flow
1. Email/password: `POST /w/v3/user/login`
2. Social (Google, Facebook, Apple): `/w/v3/user/{provider}/login`
3. Token-based: `/w/v3/user/token/login` (deep links, mobile handoff)

### Token Management
- JWT access token stored in Vuex state and cookie
- Knock token (for notifications) stored separately
- Token attached via request interceptor

### Session Initialization
- Reads token from cookie on SSR
- Fetches user profile if token exists
- Sets active workspace/roster member

## Mobile Auth (Flutter)

### Supported Methods
1. Email/Password
2. Facebook (`flutter_facebook_auth`)
3. Apple Sign-In (`sign_in_with_apple`)
4. Google Sign-In (`google_sign_in`)

### Token Storage
- `flutter_secure_storage` for sensitive data
- `AuthDataStorageService` persists `AuthData`
