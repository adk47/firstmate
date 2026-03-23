# Web Credits Configuration

## Environment Setup

### Prerequisites
- Node.js 16+
- npm or yarn

### Local Development

1. Clone the repository:
```bash
cd web-credits
```

2. Install dependencies:
```bash
npm install
```

3. Copy environment template:
```bash
cp .env.example .env
```

4. Configure environment variables (see below)

5. Start development server:
```bash
npm run dev
```

The app runs at `http://localhost:3000`

## Environment Variables

### API Configuration
```
API_URL=http://localhost:4000
API_BASE_URL=/api
```

### Auth0
```
AUTH0_DOMAIN=<tenant>.auth0.com
AUTH0_CLIENT_ID=<client-id>
AUTH0_AUDIENCE=<api-identifier>
```

### Analytics
```
AMPLITUDE_API_KEY=<key>
SEGMENT_WRITE_KEY=<key>
```

### Feature Flags
```
FEATURE_NEW_ANALYTICS=true
FEATURE_CATALOG_AUDITS=true
```

## Nuxt Configuration

Key settings in `nuxt.config.js`:

```javascript
export default {
  // Build target
  target: 'server',
  ssr: true,

  // Runtime config (available in browser)
  publicRuntimeConfig: {
    apiUrl: process.env.API_URL,
    auth0Domain: process.env.AUTH0_DOMAIN,
    auth0ClientId: process.env.AUTH0_CLIENT_ID,
  },

  // Build modules
  buildModules: [
    '@nuxt/typescript-build',
    '@nuxtjs/tailwindcss',
  ],

  // Modules
  modules: [
    '@nuxtjs/axios',
    '@nuxtjs/auth-next',
  ],
}
```

## Tailwind Configuration

```javascript
// tailwind.config.js
module.exports = {
  content: [
    './components/**/*.{vue,js}',
    './pages/**/*.vue',
  ],
  theme: {
    extend: {
      colors: {
        muso: {
          primary: '#6366f1',
          secondary: '#8b5cf6',
          // ... brand colors
        },
      },
    },
  },
}
```

## Build & Deploy

```bash
# Development
npm run dev

# Build for production
npm run build

# Start production server
npm run start

# Generate static site
npm run generate

# Lint
npm run lint

# Type check
npm run typecheck
```

## Testing

```bash
# Run unit tests
npm run test

# Run e2e tests
npm run test:e2e

# Run with coverage
npm run test:coverage
```
