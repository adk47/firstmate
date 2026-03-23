# Web Credits Patterns

## Page Component Pattern

```vue
<!-- pages/profile/_id.vue -->
<template>
  <div class="profile-page">
    <ProfileHeader :profile="profile" />
    <ProfileCredits :credits="credits" @update="handleCreditsUpdate" />
  </div>
</template>

<script lang="ts">
import { defineComponent, ref, useFetch } from '@nuxtjs/composition-api';
import { profileService } from '~/entities/profile/service';

export default defineComponent({
  async asyncData({ params, error }) {
    try {
      const profile = await profileService.getById(params.id);
      const credits = await profileService.getCredits(params.id);
      return { profile, credits };
    } catch (e) {
      error({ statusCode: 404, message: 'Profile not found' });
    }
  },

  methods: {
    async handleCreditsUpdate(credits) {
      await profileService.updateCredits(this.profile.id, credits);
      this.$toast.success('Credits updated');
    },
  },
});
</script>
```

## Vuex Store Pattern

```typescript
// store/auth.ts
import { Module } from 'vuex';

interface AuthState {
  user: User | null;
  token: string | null;
}

export const auth: Module<AuthState, RootState> = {
  namespaced: true,

  state: () => ({
    user: null,
    token: null,
  }),

  mutations: {
    SET_USER(state, user: User) {
      state.user = user;
    },
    SET_TOKEN(state, token: string) {
      state.token = token;
    },
    LOGOUT(state) {
      state.user = null;
      state.token = null;
    },
  },

  actions: {
    async login({ commit }, credentials) {
      const { user, token } = await authService.login(credentials);
      commit('SET_USER', user);
      commit('SET_TOKEN', token);
    },

    logout({ commit }) {
      commit('LOGOUT');
    },
  },

  getters: {
    isLoggedIn: (state) => !!state.token,
    currentUser: (state) => state.user,
  },
};
```

## Pinia Store Pattern (New Features)

```typescript
// stores/feed.ts
import { defineStore } from 'pinia';
import { feedService } from '~/entities/feed/service';

export const useFeedStore = defineStore('feed', {
  state: () => ({
    items: [] as FeedItem[],
    loading: false,
    hasMore: true,
  }),

  actions: {
    async fetchFeed(refresh = false) {
      if (this.loading) return;
      
      this.loading = true;
      try {
        const cursor = refresh ? undefined : this.items[this.items.length - 1]?.id;
        const { items, hasMore } = await feedService.getFeed({ cursor });
        
        if (refresh) {
          this.items = items;
        } else {
          this.items.push(...items);
        }
        this.hasMore = hasMore;
      } finally {
        this.loading = false;
      }
    },
  },
});
```

## Composable Pattern

```typescript
// composables/useAnalytics.ts
import { ref, computed, onMounted } from '@nuxtjs/composition-api';
import { analyticsService } from '~/entities/analytics/service';

export function useAnalytics(profileId: string) {
  const summary = ref<AnalyticsSummary | null>(null);
  const loading = ref(true);
  const error = ref<Error | null>(null);

  const totalStreams = computed(() => summary.value?.totalStreams ?? 0);

  async function fetchSummary() {
    loading.value = true;
    error.value = null;
    try {
      summary.value = await analyticsService.getSummary(profileId);
    } catch (e) {
      error.value = e as Error;
    } finally {
      loading.value = false;
    }
  }

  onMounted(fetchSummary);

  return {
    summary,
    loading,
    error,
    totalStreams,
    refresh: fetchSummary,
  };
}
```

## Component Pattern

```vue
<!-- components/shared/analytics/StreamsChart.vue -->
<template>
  <div class="streams-chart">
    <div v-if="loading" class="loading-skeleton" />
    <v-chart v-else :option="chartOption" autoresize />
  </div>
</template>

<script lang="ts">
import { defineComponent, computed, PropType } from '@nuxtjs/composition-api';
import VChart from 'vue-echarts';

export default defineComponent({
  components: { VChart },

  props: {
    data: {
      type: Array as PropType<StreamData[]>,
      required: true,
    },
    loading: {
      type: Boolean,
      default: false,
    },
  },

  setup(props) {
    const chartOption = computed(() => ({
      xAxis: {
        type: 'category',
        data: props.data.map(d => d.date),
      },
      yAxis: { type: 'value' },
      series: [{
        type: 'line',
        data: props.data.map(d => d.streams),
        smooth: true,
      }],
    }));

    return { chartOption };
  },
});
</script>
```

## Middleware Pattern

```typescript
// middleware/auth.ts
import { Middleware } from '@nuxt/types';

const authMiddleware: Middleware = ({ store, redirect, route }) => {
  const isLoggedIn = store.getters['auth/isLoggedIn'];
  const requiresAuth = route.meta.some(m => m.requiresAuth);

  if (requiresAuth && !isLoggedIn) {
    redirect('/login', { redirect: route.fullPath });
  }
};

export default authMiddleware;
```

## Form Validation Pattern

```vue
<template>
  <el-form ref="form" :model="form" :rules="rules" @submit.prevent="handleSubmit">
    <el-form-item prop="email" label="Email">
      <el-input v-model="form.email" type="email" />
    </el-form-item>
    <el-button type="primary" native-type="submit" :loading="submitting">
      Submit
    </el-button>
  </el-form>
</template>

<script lang="ts">
export default defineComponent({
  data() {
    return {
      form: { email: '' },
      rules: {
        email: [
          { required: true, message: 'Email is required', trigger: 'blur' },
          { type: 'email', message: 'Invalid email', trigger: 'blur' },
        ],
      },
      submitting: false,
    };
  },

  methods: {
    async handleSubmit() {
      const valid = await this.$refs.form.validate().catch(() => false);
      if (!valid) return;

      this.submitting = true;
      try {
        await this.submitForm();
      } finally {
        this.submitting = false;
      }
    },
  },
});
</script>
```
