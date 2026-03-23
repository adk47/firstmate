# Core Backend Configuration

## Environment Setup

### Prerequisites
- Node.js 16+
- PostgreSQL 13+
- Redis 6+
- AWS CLI configured

### Local Development

1. Clone the repository:
```bash
cd core-backend
```

2. Install dependencies:
```bash
npm install
```

3. Copy environment template:
```bash
cp .env.example .env.local
```

4. Configure required environment variables (see below)

5. Run database migrations:
```bash
npm run migrate
```

6. Start the development server:
```bash
npm run dev
```

## Environment Variables

### Database
```
DB_HOST=localhost
DB_PORT=5432
DB_NAME=muso_core
DB_USER=postgres
DB_PASSWORD=<password>
DB_REPLICA_HOST=<optional read replica>
```

### Redis
```
REDIS_HOST=localhost
REDIS_PORT=6379
REDIS_PASSWORD=<password>
```

### Auth0
```
AUTH0_DOMAIN=<tenant>.auth0.com
AUTH0_CLIENT_ID=<client-id>
AUTH0_CLIENT_SECRET=<secret>
AUTH0_AUDIENCE=<api-identifier>
```

### Stripe
```
STRIPE_SECRET_KEY=sk_<key>
STRIPE_WEBHOOK_SECRET=whsec_<secret>
STRIPE_PRICE_ID_PRO=price_<id>
```

### AWS
```
AWS_REGION=us-west-2
AWS_ACCESS_KEY_ID=<key>
AWS_SECRET_ACCESS_KEY=<secret>
SQS_QUEUE_URL=<queue-url>
S3_BUCKET=<bucket>
```

### External Services
```
CATALOG_API_URL=<industry-data-processing-url>
KNOCK_API_KEY=<key>
AMPLITUDE_API_KEY=<key>
SEGMENT_WRITE_KEY=<key>
```

## Database Connections

| Database | Purpose |
|----------|---------|
| `core` | Main application database |
| `analytics` | Analytics and stats (read-heavy) |
| `stats` | Platform stats data |

## Feature Flags

Feature flags are managed via environment variables:
```
FEATURE_NEW_ANALYTICS=true
FEATURE_CATALOG_AUDITS=true
FEATURE_MLC_INTEGRATION=true
```

## Logging

Logs go to CloudWatch in production. Locally:
```bash
# Set log level
LOG_LEVEL=debug npm run dev
```

## Testing

```bash
# Run all tests
npm test

# Run specific test file
npm test -- --grep "profile"

# Run with coverage
npm run test:coverage
```
