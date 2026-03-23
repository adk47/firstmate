# Core Backend Gotchas

## Flow Types, Not TypeScript

The core-backend uses **Flow types**, not TypeScript. This is a common source of confusion.

```javascript
// Correct (Flow)
// @flow
type Profile = {
  id: string,
  displayName: string,
};

// Wrong (TypeScript syntax)
interface Profile {
  id: string;
  displayName: string;
}
```

## Database Replica Lag

Read replicas have 1-3 second lag. After writes, read from primary:

```javascript
// After creating/updating, use primary connection
const profile = await Profile.create(data);
// Don't immediately query replica - data might not be there
const freshProfile = await Profile.findByPk(profile.id, { usePrimary: true });
```

## Auth0 User vs Local User

Users have both an Auth0 ID and a local database ID:

```javascript
// auth0UserId - from Auth0 (auth0|abc123)
// id - local UUID in our database
// NEVER mix these up in queries
```

## Neptune Professional ID

Profiles link to the industry catalog via `neptuneProfessionalId`:

```javascript
// This is the ID used to fetch from the industry-data-processing API
const catalogProfile = await catalogApi.getProfile(profile.neptuneProfessionalId);
```

## Subscription Hierarchy

Subscriptions can be user-level OR team-level:

```javascript
// Check both
async function hasProAccess(user) {
  const userSub = await user.getSubscription();
  if (userSub?.plan === 'pro') return true;
  
  const teamSubs = await user.getTeamSubscriptions();
  return teamSubs.some(sub => sub.plan === 'pro' || sub.plan === 'business');
}
```

## Guards Order Matters

Middleware order in routes is critical:

```javascript
// CORRECT order
router.get('/:id',
  tokenValidation,        // 1. Validate JWT
  acl(['user', 'admin']), // 2. Check role
  subscriptionGuard,      // 3. Check subscription
  profileAccessGuard,     // 4. Check profile access
  controller.get          // 5. Handle request
);

// WRONG - will fail because req.user not set
router.get('/:id',
  subscriptionGuard,      // Fails - no user context yet
  tokenValidation,
  controller.get
);
```

## SQS Message Deduplication

SQS FIFO queues have 5-minute deduplication window:

```javascript
// Include unique deduplication ID for retries
await sqs.sendMessage({
  QueueUrl: queueUrl,
  MessageBody: JSON.stringify(payload),
  MessageGroupId: `profile-${profileId}`,
  MessageDeduplicationId: `${profileId}-${Date.now()}`, // Must be unique
});
```

## Soft Deletes

Most models use soft deletes (paranoid: true):

```javascript
// This doesn't actually delete
await profile.destroy();

// To truly delete (rare)
await profile.destroy({ force: true });

// To include deleted records
await Profile.findAll({ paranoid: false });
```

## Stripe Webhook Idempotency

Stripe webhooks can be delivered multiple times:

```javascript
// Always check if already processed
const existing = await PaymentHistory.findOne({
  where: { stripeEventId: event.id }
});
if (existing) {
  return res.json({ received: true }); // Already processed
}
```

## Timezone Issues

All timestamps are UTC in the database. Convert for display only:

```javascript
// Database stores UTC
// Don't do timezone conversion in queries
// Let the frontend handle display conversion
```

## Redis Key Prefixes

Always use prefixes to avoid key collisions:

```javascript
// Good
const key = `muso:profile:${id}`;
const sessionKey = `muso:session:${userId}`;

// Bad - might collide
const key = id;
```

## Rate Limiting External APIs

Spotify, YouTube, etc. have rate limits. Use the queue system:

```javascript
// Don't call directly in request handlers
// Queue the job and return immediately
await sqsQueue.sendMessage({
  type: 'FETCH_SPOTIFY_STATS',
  profileId: id,
});
res.json({ success: true, message: 'Stats update queued' });
```

## Environment Variable Gotchas

```javascript
// Environment variables are strings
const enabled = process.env.FEATURE_FLAG === 'true'; // String comparison

// Not this
const enabled = process.env.FEATURE_FLAG; // Truthy even if 'false'
```
