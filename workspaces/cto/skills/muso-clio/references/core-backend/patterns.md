# Core Backend Patterns

## API Route Pattern

```javascript
// apis/profile/index.js
const router = require('express').Router();
const controller = require('./controller');
const { tokenValidation, acl } = require('../../middleware');
const { subscriptionGuard, profileAccessGuard } = require('../../guards');

router.get(
  '/:id',
  tokenValidation,
  acl(['user', 'admin']),
  profileAccessGuard,
  controller.getProfile
);

router.get(
  '/:id/stats',
  tokenValidation,
  acl(['user', 'admin']),
  subscriptionGuard('pro'),
  profileAccessGuard,
  controller.getProfileStats
);

module.exports = router;
```

## Controller Pattern

```javascript
// apis/profile/controller.js
const profileService = require('../../components/profile');

exports.getProfile = async (req, res, next) => {
  try {
    const { id } = req.params;
    const profile = await profileService.getById(id, req.user);
    res.json({ success: true, data: profile });
  } catch (error) {
    next(error);
  }
};
```

## Service Pattern

```javascript
// components/profile/index.js
const { Profile, ProfileCredits } = require('../../models');
const { catalogApi } = require('../../services/catalog');

class ProfileService {
  async getById(id, requestingUser) {
    const profile = await Profile.findByPk(id, {
      include: [{ model: ProfileCredits, as: 'credits' }]
    });
    
    if (!profile) {
      throw new NotFoundError('Profile not found');
    }
    
    // Enrich with catalog data
    const catalogData = await catalogApi.getProfile(profile.neptuneProfessionalId);
    
    return this.formatProfile(profile, catalogData);
  }
}

module.exports = new ProfileService();
```

## Guards Pattern

Guards are composable middleware for authorization:

```javascript
// guards/subscriptionGuard.js
const subscriptionGuard = (requiredPlan) => async (req, res, next) => {
  const { user } = req;
  const subscription = await user.getActiveSubscription();
  
  if (!subscription || !subscription.hasAccess(requiredPlan)) {
    return res.status(403).json({
      success: false,
      error: { code: 'SUBSCRIPTION_REQUIRED', message: 'Upgrade required' }
    });
  }
  
  next();
};
```

## SQS Worker Pattern

```javascript
// workers/notifications.js
const { Consumer } = require('sqs-consumer');
const { processNotification } = require('../components/notifications');

const consumer = Consumer.create({
  queueUrl: process.env.SQS_NOTIFICATIONS_URL,
  handleMessage: async (message) => {
    const payload = JSON.parse(message.Body);
    await processNotification(payload);
  },
  batchSize: 10,
});

consumer.on('error', (err) => logger.error('SQS Error', err));
consumer.on('processing_error', (err) => logger.error('Processing Error', err));

module.exports = consumer;
```

## Sequelize Model Pattern

```javascript
// models/Profile.js
module.exports = (sequelize, DataTypes) => {
  const Profile = sequelize.define('Profile', {
    id: {
      type: DataTypes.UUID,
      defaultValue: DataTypes.UUIDV4,
      primaryKey: true,
    },
    neptuneProfessionalId: {
      type: DataTypes.STRING,
      allowNull: true,
    },
    displayName: {
      type: DataTypes.STRING,
      allowNull: false,
    },
    // ... other fields
  }, {
    tableName: 'profiles',
    timestamps: true,
    paranoid: true, // soft deletes
  });

  Profile.associate = (models) => {
    Profile.hasMany(models.ProfileCredits, { as: 'credits' });
    Profile.belongsToMany(models.Team, { through: 'RosterSeats' });
  };

  return Profile;
};
```

## Error Handling Pattern

```javascript
// errors/index.js
class AppError extends Error {
  constructor(message, statusCode, code) {
    super(message);
    this.statusCode = statusCode;
    this.code = code;
  }
}

class NotFoundError extends AppError {
  constructor(message = 'Resource not found') {
    super(message, 404, 'NOT_FOUND');
  }
}

class ForbiddenError extends AppError {
  constructor(message = 'Access denied') {
    super(message, 403, 'FORBIDDEN');
  }
}

// Error middleware
const errorHandler = (err, req, res, next) => {
  const statusCode = err.statusCode || 500;
  const code = err.code || 'INTERNAL_ERROR';
  
  logger.error(err);
  
  res.status(statusCode).json({
    success: false,
    error: { code, message: err.message }
  });
};
```

## Caching Pattern

```javascript
// services/cache.js
const redis = require('../config/redis');

const CACHE_TTL = 300; // 5 minutes

async function cacheGet(key) {
  const cached = await redis.get(key);
  return cached ? JSON.parse(cached) : null;
}

async function cacheSet(key, value, ttl = CACHE_TTL) {
  await redis.setex(key, ttl, JSON.stringify(value));
}

async function cacheDel(pattern) {
  const keys = await redis.keys(pattern);
  if (keys.length) {
    await redis.del(...keys);
  }
}

// Usage in service
async function getProfile(id) {
  const cacheKey = `profile:${id}`;
  
  let profile = await cacheGet(cacheKey);
  if (profile) return profile;
  
  profile = await Profile.findByPk(id);
  await cacheSet(cacheKey, profile);
  
  return profile;
}
```
