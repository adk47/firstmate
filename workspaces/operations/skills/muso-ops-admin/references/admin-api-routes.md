# Admin API — Verified Route Map

_Source: `core-backend/src/apis/index.w.js` (re-verified 2026-03-15)_
_Base URL: `https://api.muso.ai/api/v3` — routes use `/admin/*` prefix (NOT `/w/admin/`)_
_Auth: JWT Bearer token from `data.authentication.accessToken`. All routes require `admin` role except login._
_Service account: `retool@muso.ai` (same account Retool uses)_
_Required headers: `Authorization: Bearer <token>`, `Requester: <user-email>`, `Service: clio`; optional audit headers `Approved-By`, `Request-Ref` (sent when `--confirmed-by` / `--approval-msg-id` are given)_

## User Management
| Method | Path | Handler | Notes |
|--------|------|---------|-------|
| POST | `/admin/user/login` | user.login | No ACL (public) |
| GET | `/admin/user` | user.list | List/search users |
| POST | `/admin/user` | user.createUser | |
| PUT | `/admin/user/:id` | user.updateUser | |
| DELETE | `/admin/user/:id` | user.deleteUser | ⚠️ Aaron only |
| POST | `/admin/user/:id/impersonate` | user.getImpersonateUrl | ⚠️ Escalate |
| PUT | `/admin/user/:id/image` | user.uploadUserImage | fileUpload middleware |
| POST | `/admin/user/:id/reset-password` | user.resetPassword | |
| POST | `/admin/user/:id/email-confirmed` | user.emailConfirmed | |
| POST | `/admin/user/:id/resend-email-confirmation` | user.resendEmailConfirmation | |
| POST | `/admin/user/:userId/events` | user.trackEvents | |
| POST | `/admin/user/:userId/backfill-profile` | user.backfillUserProfile | |
| GET | `/admin/user/:userId/workspace/:workspaceId/profile/:profileId` | profile.createNfcCardLink | NFC card link |

## Claiming
| Method | Path | Handler |
|--------|------|---------|
| GET | `/admin/claiming` | claiming.list |
| GET | `/admin/claiming/:id` | claiming.item |
| POST | `/admin/claiming/:id/reject` | claiming.reject |
| POST | `/admin/claiming/:id/verify` | claiming.verify |
| POST | `/admin/claiming/:id/revert` | claiming.revert |

## Profile Management
| Method | Path | Handler | Notes |
|--------|------|---------|-------|
| GET | `/admin/profile` | profile.list | |
| POST | `/admin/profile` | profile.createProfile | |
| GET | `/admin/profile/search` | profile.searchArtistsAndProfessionals | |
| PUT | `/admin/profile/:professionalId/image` | profile.uploadProfileAvatar | fileUpload |
| POST | `/admin/profile/enrichByUrl` | profile.enrichByUrl | |
| POST | `/admin/artist/:spotifyId/enrich` | profile.enrichSpotify | |
| POST | `/admin/profiles/merge` | profile.mergeProfiles | Body: source+target IDs |
| POST | `/admin/profiles/unmerge` | profile.unmergeProfiles | |
| DELETE | `/admin/profile/:profileId/cache` | profile.clearProfileCache | |
| GET | `/admin/profile/:profileId/collaborators` | profile.listCollaborators | |
| GET | `/admin/profile/:profileId/credits` | profile.listCredits | |
| PUT | `/admin/profile/:profileId/credits` | profile.updateCredits | |
| POST | `/admin/profile/:profileId/credits` | profile.addCredits | |
| DELETE | `/admin/profile/:profileId/credits` | profile.deleteCredits | |
| POST | `/admin/profile/:profileId/unlink` | profile.unlinkProfile | |
| POST | `/admin/profile/:profileId/link-external` | profile.linkExternalIds | |
| POST | `/admin/profile/:profileId/unlink-external` | profile.unlinkExternalIds | |
| PUT | `/admin/profile/:profileId` | profile.updateProfile | |
| GET | `/admin/profile/:profileId` | profile.getProfile | |
| PUT | `/admin/profile/:profileId/member` | profile.updateMember | |
| POST | `/admin/profile/:profileId/member` | profile.addMember | |
| DELETE | `/admin/profile/:profileId/member` | profile.removeMember | |
| GET | `/admin/profile/:profileId/member` | profile.getMembers | |
| GET | `/admin/profile/:profileId/membership` | profile.getMemberships | |
| GET | `/admin/profile/:profileId/charts` | profile.getProfileCharts | |
| POST | `/admin/profile/:profileId/encore-assets/generate` | profile.generateEncoreProfileAssets | |
| PUT | `/admin/profile/:profileId/playlist/:status` | profile.updateProfilePlaylistStatus | |
| POST | `/admin/profile/:profileId/playlist/regenerate` | profile.regenerateProfilePlaylist | |

## Profile Member Actions
| Method | Path | Handler |
|--------|------|---------|
| GET | `/admin/profile-member-actions` | profileMemberActions.list |
| POST | `/admin/profile-member-actions/:id/revert` | profileMemberActions.revert |
| POST | `/admin/profile-member-actions/:id/approve` | profileMemberActions.approve |

## Audit
| Method | Path | Handler |
|--------|------|---------|
| GET | `/admin/profile/:profileId/audit` | audit.getProfileAuditStatus |
| POST | `/admin/profile/:profileId/audit/generate` | audit.generateProfileAudit |

## Professional Credits Export
| Method | Path | Handler |
|--------|------|---------|
| GET | `/admin/professional/:professionalId/credits/export` | profile.exportProfessionalCredits |

## Organizations
| Method | Path | Handler |
|--------|------|---------|
| GET | `/admin/organizations/search` | profile.searchOrganizations |
| GET | `/admin/organizations/roles` | role.getOrganizationRoles |

## Spotify
| Method | Path | Handler |
|--------|------|---------|
| GET | `/admin/spotify/search-tracks-albums` | spotify.searchTracksAndAlbums |

## Roles
| Method | Path | Handler |
|--------|------|---------|
| GET | `/admin/roles` | role.getRoles |

## Worker Process
| Method | Path | Handler |
|--------|------|---------|
| POST | `/admin/worker-process/add` | workerProcess.addRecord |
| POST | `/admin/worker-process/execute` | workerProcess.executeTask |

## Analytics
| Method | Path | Handler |
|--------|------|---------|
| POST | `/admin/analytics/:profileId/recalculate` | analytics.recalculateAnalyticsForProfile |
| PUT | `/admin/analytics/recalculate` | analytics.recalculate |
| PUT | `/admin/analytics/lists/:listId/high-queue` | analytics.addListToHighQueue |

## Track Management
| Method | Path | Handler |
|--------|------|---------|
| GET | `/admin/track/:trackId` | track.getTrack |
| DELETE | `/admin/track/:trackId` | track.deleteTrack |
| GET | `/admin/track/:trackId/sources` | track.getTrackSources |
| GET | `/admin/track/:trackId/analytics-sources` | track.getTrackAnalyticsSources |
| DELETE | `/admin/track/:trackId/analytics-sources` | track.deleteAnalyticsLink |
| POST | `/admin/track/:trackId/analytics-sources` | track.addAnalyticsLink |
| PATCH | `/admin/track/:trackId/analytics-sources` | track.moveAnalyticsLink |
| GET | `/admin/track/:trackId/raw-credits` | track.getTrackRawCredits |
| POST | `/admin/track/:trackId/profile/:profileId/credits` | track.addTrackProfileCredits |
| DELETE | `/admin/track/:trackId/profile/:profileId/credits` | track.deleteTrackProfileCredits |
| POST | `/admin/tracks/merge` | track.mergeTracks |
| POST | `/admin/tracks/unmerge` | track.unmergeTracks |
| GET | `/admin/track` | track.getTracks |
| POST | `/admin/track/enrichByUrl` | track.enrichByUrl |
| POST | `/admin/track/capture/:trackId` | track.captureById |
| GET | `/admin/tracks/search` | track.searchTracks |

## Album Management
| Method | Path | Handler |
|--------|------|---------|
| GET | `/admin/album/:albumId` | album.getAlbum |
| GET | `/admin/album/:albumId/credits` | album.getAlbumCredits |
| GET | `/admin/album/:albumId/sources` | album.getAlbumSources |
| POST | `/admin/album/enrichByUrl` | album.enrichByUrl |
| POST | `/admin/album/capture/:albumId` | album.enrichById |

## Team/Workspace Management
| Method | Path | Handler |
|--------|------|---------|
| POST | `/admin/team` | team.createTeam |
| GET | `/admin/team` | team.listTeams |
| GET | `/admin/team/details` | team.getDetails |
| PUT | `/admin/team/:id` | team.updateTeam |
| POST | `/admin/team/:id/subscription-sync` | team.syncWorkspaceSubscription |
| GET | `/admin/team/:id/users` | team.listTeamUsers |
| POST | `/admin/team/:id/users` | team.addUsersToTheTeam |
| POST | `/admin/team/:id/invite-users` | team.inviteUsersToWorkspace |
| PUT | `/admin/team/:id/users/:userId` | team.updateTeamUser |
| DELETE | `/admin/team/:id/users/:userId` | team.removeTeamUser |
| GET | `/admin/team/:id/seats` | team.getTeamSeats |
| GET | `/admin/team/:id/entities` | team.getWorkspaceEntitiesAdmin |
| POST | `/admin/team/:id/seats` | team.addTeamSeats |
| PUT | `/admin/team/:id/seats/:seatId` | team.updateTeamSeat |
| DELETE | `/admin/team/:id/seats/:seatId` | team.deleteTeamSeat |
| POST | `/admin/team/:id/roster/:seatId/claim` | team.claimSeat |
| PUT | `/admin/team/:id/image` | team.uploadTeamImage | fileUpload |
| POST | `/admin/team/:id/subscription/checkout` | payments.getAdminTeamCheckoutUrl |
| POST | `/admin/team/:id/lists/default` | team.syncWorkspaceDefaultLists |
| PUT | `/admin/team/:id/lists/:listId/profiles` | lists.upsertWorkspaceListSeats |
| GET | `/admin/lists/:listId` | lists.getList |
| DELETE | `/admin/team/:id/lists/:listId` | lists.deleteList |
| POST | `/admin/team/:id/lists` | lists.createList |
| PATCH | `/admin/team/:id/lists/:listId` | lists.updateList |
| PUT | `/admin/team/:id/lists/:listId/profiles/:profileId` | lists.updateListSeat |

## Workspace Keys
| Method | Path | Handler |
|--------|------|---------|
| POST | `/admin/workspace/:workspaceId/key` | team.addKey |
| DELETE | `/admin/workspace/:workspaceId/key` | team.removeWorkspaceKey |

## Workspace Checklist
| Method | Path | Handler |
|--------|------|---------|
| GET | `/admin/workspace/:workspaceId/checklist/populate` | checklist.populateWorkspaceChecklist |
| GET | `/admin/workspace/:workspaceId/checklist/reset` | checklist.resetWorkspaceChecklist |

## Ads
| Method | Path | Handler |
|--------|------|---------|
| POST | `/admin/ads` | ads.createAd | fileUpload |
| PUT | `/admin/ads/:adId` | ads.updateAd | ← NEW! Update endpoint exists now |

## Articles
| Method | Path | Handler |
|--------|------|---------|
| GET | `/admin/article` | article.listArticles |
| POST | `/admin/article` | article.createArticle |
| POST | `/admin/article/upload` | article.uploadImage | fileUpload |
| GET | `/admin/article/:articleId` | article.getArticle |
| DELETE | `/admin/article/:articleId` | article.deleteArticle |
| PUT | `/admin/article/:articleId` | article.updateArticle |

## Orders (Encore)
| Method | Path | Handler |
|--------|------|---------|
| GET | `/admin/orders` | orders.listOrders |
| POST | `/admin/orders` | orders.createOrder |
| PUT | `/admin/orders/:orderId` | orders.updateOrder |
| POST | `/admin/orders/:orderId/complete-for-free` | orders.completeOrderForFree |
| POST | `/admin/orders/:orderId/retry-prodigi-order-create` | orders.retryProdigiOrderCreate |
| PUT | `/admin/orders/:orderId/tracking` | orders.updateOrderTracking |

## Marketplace Products
| Method | Path | Handler |
|--------|------|---------|
| POST | `/admin/marketplace-products` | marketplaceProducts.createMarketplaceProduct |
| PUT | `/admin/marketplace-products/:id` | marketplaceProducts.updateMarketplaceProduct |

## Media
| Method | Path | Handler |
|--------|------|---------|
| POST | `/admin/media/upload` | media.uploadImage | fileUpload |

## Payments / Subscriptions
| Method | Path | Handler |
|--------|------|---------|
| GET | `/admin/payments/apple/lookup` | payments.lookupAppleOrderId |
| GET | `/admin/subscription/daily` | payments.runUpdateSubscriptionsDaily |
| GET | `/admin/subscription` | payments.listSubscriptions |
| POST | `/admin/subscription` | payments.createVIPSubscription | ⚠️ Aaron only |
| PUT | `/admin/subscription/:subscriptionId` | payments.updateSubscription |
| GET | `/admin/subscription/:subscriptionId` | payments.getSubscriptionDetails |
| POST | `/admin/subscription/:subscriptionId/cancel` | payments.cancelSubscription |
| GET | `/admin/subscription-info` | payments.getSubscriptionInfo |

## Platform
| Method | Path | Handler |
|--------|------|---------|
| POST | `/admin/platform/request-ingestion` | platform.requestDataIngestion |

## Credit Requests
| Method | Path | Handler |
|--------|------|---------|
| GET | `/admin/credit-requests` | creditRequests.list |
| PUT | `/admin/credit-requests` | creditRequests.updateStatus |
| GET | `/admin/credit-requests/counts` | creditRequests.counts |
| PUT | `/admin/credit-requests/:requestId` | creditRequests.update |
| GET | `/admin/credit-requests/profiles` | creditRequests.listProfiles |

## Feed
| Method | Path | Handler |
|--------|------|---------|
| POST | `/admin/feed/:profileId/populate` | feed.populateProfileFeed |

## Identity Resolution
| Method | Path | Handler |
|--------|------|---------|
| GET | `/admin/identity-resolution` | identityResolution.list |
| GET | `/admin/identity-resolution/:userId` | identityResolution.getByUser |
| PUT | `/admin/identity-resolution/:id/confirm` | identityResolution.confirm |
| PUT | `/admin/identity-resolution/:id/reject` | identityResolution.reject |

## Clients (OAuth)
| Method | Path | Handler |
|--------|------|---------|
| GET | `/admin/clients` | clients.list |
| POST | `/admin/clients` | clients.create |
| DELETE | `/admin/clients/:clientId` | clients.deleteClient |

---

**Total verified routes: 139**
**Deprecated: 1** (`/admin/analytics/:trackId/sources`)
**New in 2026-03-15 re-verification:**
- `GET /admin/ads/targeting-debug` — ads targeting debug (was missing)
- Confirmed base URL is `/api/v3` (NOT `/w/`) — all `/w/admin/` references in skills are WRONG, use `/admin/`
