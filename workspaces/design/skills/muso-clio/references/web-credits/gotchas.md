# Web Credits Gotchas

## Vuex vs Pinia

The codebase uses **both** Vuex and Pinia:
- **Vuex**: Core stores (auth, roster, subscription, claim)
- **Pinia**: New features (feed, audit-export)

```typescript
// Vuex access
this.$store.state.auth.user
this.$store.dispatch('auth/login', credentials)

// Pinia access
const feedStore = useFeedStore();
feedStore.items
feedStore.fetchFeed()
```

Don't mix them - use the pattern established for each feature.

## asyncData vs fetch

- **asyncData**: Blocks navigation, data available immediately
- **fetch**: Non-blocking, shows loading state

```vue
<!-- Use asyncData for critical data -->
<script>
export default {
  async asyncData({ params }) {
    // Page won't render until this completes
    const profile = await profileService.getById(params.id);
    return { profile };
  },
}
</script>

<!-- Use fetch for secondary data -->
<script>
export default {
  data() {
    return { relatedProfiles: [] };
  },
  async fetch() {
    // Page renders immediately, this loads in background
    this.relatedProfiles = await profileService.getRelated(this.profile.id);
  },
}
</script>
```

## SSR Gotchas

### No window/document on Server

```typescript
// WRONG - crashes on SSR
export default {
  mounted() {
    window.scrollTo(0, 0); // OK - mounted only runs on client
  },
  created() {
    localStorage.getItem('key'); // CRASH - created runs on server too
  },
}

// CORRECT
export default {
  created() {
    if (process.client) {
      localStorage.getItem('key');
    }
  },
}
```

### Plugin Client-Only

```javascript
// nuxt.config.js
plugins: [
  { src: '~/plugins/charts.js', mode: 'client' }, // Only loads on client
  '~/plugins/axios.js', // Loads on both
]
```

## Element UI Gotchas

### Form Validation Async

```typescript
// WRONG - validate() returns a Promise
const valid = this.$refs.form.validate();
if (valid) { ... } // Always truthy (Promise object)

// CORRECT
const valid = await this.$refs.form.validate().catch(() => false);
if (valid) { ... }
```

### Table Slot Syntax

```vue
<!-- WRONG (deprecated) -->
<el-table-column>
  <template slot-scope="{ row }">
    {{ row.name }}
  </template>
</el-table-column>

<!-- CORRECT (Vue 2.6+) -->
<el-table-column>
  <template #default="{ row }">
    {{ row.name }}
  </template>
</el-table-column>
```

## Tailwind + Element UI Conflicts

Element UI has its own styling. Use Tailwind for layout, Element UI for components:

```vue
<!-- GOOD - Tailwind for layout, Element for component -->
<div class="flex gap-4 p-4">
  <el-button type="primary">Submit</el-button>
</div>

<!-- RISKY - Tailwind might conflict with Element styles -->
<el-button class="bg-blue-500 text-white">Submit</el-button>
```

## Route Parameter Reactivity

```vue
<!-- WRONG - asyncData doesn't re-run on param change -->
<script>
export default {
  async asyncData({ params }) {
    return { profile: await fetchProfile(params.id) };
  },
  // Navigating /profile/1 -> /profile/2 won't refetch!
}
</script>

<!-- CORRECT - watch for param changes -->
<script>
export default {
  async asyncData({ params }) {
    return { profile: await fetchProfile(params.id) };
  },
  watch: {
    '$route.params.id': {
      async handler(newId) {
        this.profile = await fetchProfile(newId);
      },
    },
  },
}
</script>
```

## Composition API with Nuxt 2

```typescript
// Import from @nuxtjs/composition-api, NOT vue
import { ref, computed, onMounted } from '@nuxtjs/composition-api';

// NOT this
import { ref, computed, onMounted } from 'vue';
```

## TypeScript Strictness

The project has moderate TypeScript strictness. Common issues:

```typescript
// Element refs need type casting
const formRef = ref<InstanceType<typeof ElForm> | null>(null);

// API responses need typing
interface ProfileResponse {
  success: boolean;
  data: Profile;
}
const response = await $axios.get<ProfileResponse>('/api/v4/profile/1');
```

## Environment Variable Access

```typescript
// In component - use $config
this.$config.apiUrl

// In service/utility - use process.env with runtime config
const apiUrl = process.env.API_URL || 'http://localhost:4000';
```

## Hydration Mismatches

Server and client renders must match:

```vue
<!-- WRONG - different on server vs client -->
<div>{{ new Date().toLocaleString() }}</div>

<!-- CORRECT - use client-only -->
<client-only>
  <div>{{ new Date().toLocaleString() }}</div>
</client-only>
```
