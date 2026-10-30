# Post moderation, private contact, community and local asking-price API

Prefix `/api/v1`. JSON is strict camelCase; unknown request properties are rejected. Existing opaque bearer sessions, approval policies and message idempotency remain in force. This contract describes API behavior; deployment and native UI acceptance have separate receipts.

## Posts

`POST /posts` requires an active Approved Producer or Trader. Existing clients may keep sending only:

```json
{"title":"Mango forecast","body":"Future availability for discussion only.","productCode":"mango","estimatedQuantityKg":20}
```

Optional fields:

| Field | Contract |
|---|---|
| region | 2–120 valid characters after trim/normalization; omitted uses the author's region |
| purpose | `Supply` or `Demand`; Producer defaults to and may only submit Supply; new Trader posts default Demand but may explicitly choose either |
| availableOn | Nullable `YYYY-MM-DD`; from yesterday through two years ahead, based on server UTC date |
| priceMinVndPerKg / priceMaxVndPerKg | Both null or both supplied; positive, max ≥ min, max ≤ 1,000,000,000, at most two decimal places |

Creation returns `201`, status `AwaitingReview`, revision `1`, and `Location: /api/v1/posts/{id}`. Fields returned include id/title/body/productCode/status/sourceType/estimatedQuantityKg/createdAt/revision/reviewedAt, region/purpose/availableOn/price ranges, and `author:{id,displayName,region}`. `actualStockKg` remains null and `canOrder` false: forecasts and asking prices do not create stock or orders.

- `GET /posts?limit=20&after=<guid>`: public Published posts with an active Approved author, newest `createdAt DESC,id DESC`. Cursor resolves an anchor inside the visible query; invalid/hidden anchors return `400`. Response `{items,next}`; limit 1–50.
- `GET /posts/{id}`: published visible content is public; the author or active Approved Admin may also read private/unpublished content. Hidden others receive `404`.
- `GET /me/posts?limit&after`: current author's expanded private records, same newest-first cursor semantics.
- `GET /admin/posts?status&limit&after`: Admin only. Optional status is AwaitingReview, Published, Rejected or Paused. No status returns those four workflow states. Legacy Draft/NeedsChanges/Closed remain stored and accessible to author/Admin by ID, but are outside the new moderation graph.

`reviewReason` is included only in author/Admin private responses and omitted from public list/detail. Review metadata is never accepted from the submitter.

### Review

`POST /admin/posts/{id}/review`, active Approved Admin only:

```json
{"status":"Published","reason":"Reviewed availability description","expectedRevision":1}
```

Reason requires 3–1000 safe characters; expectedRevision is required and ≥1. Allowed transitions:

| Current | Next |
|---|---|
| AwaitingReview | Published or Rejected |
| Published | Paused |
| Paused | Published |

Rejected has no transition in this slice. Invalid transitions or stale revisions return `409`; invalid request values return `400`; unknown ID `404`. Publishing requires the author to remain active and Approved, otherwise `409`. The transaction locks the post, checks the author, increments revision, records reviewer/time/reason, audit and the author's history. Concurrent reviews at the same expectedRevision can commit once. Successful review returns the expanded private post.

## Contact a published post

`POST /posts/{id}/conversations {}` requires an active Approved business user. Admin receives `403`, self-contact `409`. Post must still be published with an active Approved author, otherwise `404`. The server derives both participants; arbitrary participant IDs are rejected.

- `201` for a newly created private Direct conversation; `200` for the existing one.
- Response `{id,title,postId}`; group/conversation ID is the same underlying Conversation.Id.
- Unique `(PostId,InitiatorId)` plus transaction/advisory locking prevent duplicates under simultaneous calls. Nullable initiators preserve legacy data. An exact existing two-party Direct thread for the same post/author/caller is reused and claimed; a wider legacy group is never reused.
- New creation commits conversation, exactly two participant rows and both histories atomically. Different callers get separate private threads.

Existing `/conversations` and `/conversations/{id}/messages` remain member-only. Conversation list now returns `kind`, nullable `ownerId`, `region`, `productCode`, `isOpen` alongside id/title/postId, newest-first with the existing bounded limit. No participant list or private post body is broadcast.

Authorized message GET pages, new/retried message POST responses and durable `MessageCreated` events preserve existing fields and add `sender:{id,displayName,role}`. Role is an explicit string (Admin/Producer/Trader/Consumer) on both REST and SignalR; no email or private profile fields are included. Sender identity is derived from server user records, never request properties. Message pages join users in the same bounded SQL query; clients do not make one profile request per message. Metadata describes the sender's public identity at read/dispatch time, not an immutable historical role snapshot.

## Community groups

All routes below require an active Approved account, including Admin. Requests other than creation use strict `{}`.

| Route | Behavior |
|---|---|
| GET `/community/groups?region&productCode&limit&after` | Open Group conversations; newest-first, anchor cursor; region matching is case-insensitive, product must exist |
| POST `/community/groups` | `{title,region,productCode?}`; title 5–160 chars, region 2–120; creates owner membership, returns `201` |
| GET `/community/groups/{id}` | Metadata; a closed group is hidden from nonmembers except owner/Admin |
| POST `/community/groups/{id}/join` | `201` new membership, `200` already a member; no arbitrary user ID |
| POST `/community/groups/{id}/leave` | Idempotent `200`; owner must close an open group before leaving |
| POST `/community/groups/{id}/close` | Owner or Admin; idempotent `200`; closes discovery/join/new messages |

Group DTO: `{id,title,kind,ownerId,region,productCode,isOpen,createdAt,memberCount,isMember,currentRole}`. currentRole is Owner, Member or NonMember. Max 50 members and max 10 open owned groups; concurrent admission is serialized, quota/closed conflicts return `409`. Direct conversations cannot be joined through group routes.

Group messages use existing GET/POST conversation message endpoints. The message handler locks the same Conversation row as close/leave, checks current membership and open state. Closed members may read existing history; new messages return `409`. Retrying an already stored clientMessageId with the same text may return the existing message.

## Local supply/demand and asking prices

Public `GET /market/summary?region&productCode` returns `{region,productCode,asOf,source,isForecast,items,limitations}`. Source is `published-user-asking-prices`; top-level isForecast=false describes a reference, not an AI price prediction. **All supply/demand quantities remain user forecasts.**

Only Published posts with an active Approved author contribute. Empty legacy post regions fall back to author region. Region filter matches case-insensitively; grouping retains display labels. Product filter must exist. Aggregation is executed in PostgreSQL with parameters, at most 500 region/product groups.

Each item contains productCode/productName/region, supplyEstimatedKg/demandEstimatedKg, supplyPostCount/demandPostCount, contributorCount, referencePriceVndPerKg, priceMinVndPerKg/priceMaxVndPerKg, priceSampleCount, lastUpdated.

Reference price is the median of the midpoint of valid **Supply** asking-price ranges. Demand bids do not alter it. Min/max are the envelope of those supply ranges; sample count counts priced Supply posts; contributor count counts distinct authors across eligible posts. No price samples means null prices and zero samples, not zero/fabricated prices. asOf is response time; lastUpdated is latest contributing creation/review time. This is not an official/external market price, a transaction price, inventory or an AI forecast; repeated posts may describe the same lot.

## Realtime and recovery

Approved hub connections join `approved` and their own `user:{id}` group; Admin also joins `role:Admin`. Events below are best effort **after commit**, with REST recovery. A failed/cancelled notification does not turn a committed write into an HTTP failure.

| Event | Payload | Audience |
|---|---|---|
| PostChanged | `{eventId,postId,status,revision}` | Author user group and role:Admin after submit/review |
| PublishedPostChanged | Same four fields | Approved connections when review changes public visibility |
| ConversationCreated | `{eventId,id,postId}` | Both Direct participants, or newly joined Group user; group postId is null |
| CommunityChanged | `{eventId,id}` | Approved connections; public group metadata changed |

These events contain no private title/body/reason or arbitrary participant data. Dedup by eventId, reject older post revisions, and fetch authorized REST snapshots after events/reconnect. The durable MessageCreated outbox remains; dispatch now resolves **current DB participants** and targets their user groups, so an old conversation-group subscription does not keep delivering to someone who left. This remains one API instance; no multi-instance lease/backplane guarantee is claimed.

Global request limit stays 120/minute: authenticated users partition by server-authenticated UserId; anonymous requests by IP. Authentication runs before that partition. The separate auth endpoint limit remains 30/IP/minute, including callers who already possess another session. Tests use smaller isolated budgets; production limits were not raised for the demo.

Schema migration: `20261030120251_PostModerationAndCommunity`. It adds fields/indexes/constraints without rewriting legacy posts or narrowing legacy conversation titles. Runtime migration/deployment is a separate controlled step; tests migrate only isolated PostgreSQL databases.
