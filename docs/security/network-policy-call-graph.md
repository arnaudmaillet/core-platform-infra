# W8 v2 — Per-Service NetworkPolicy Call Graph

Basis for tightening the namespace-isolation baseline (#519) into per-service
micro-segmentation that isolates TIER-0 `audit`/`auth` from arbitrary peers.
Derived from code + config, not guesswork:

- **gRPC ports** — `k8s/base/services/*/.../{deployment,service}.yaml`.
- **gRPC mesh edges** — the tonic `*Client` types actually instantiated under
  `crates/services/*/src` (the *complete* set is 6 — see below) cross-checked with
  the `*_GRPC_ENDPOINT` config in `k8s/overlays/staging/*.env`.
- **Kafka event plane** — the generated topic-wiring in
  `docs/domain/EVENT_CATALOG.md` (authoritative: `crates/contracts/event-topology`).
- **Datastore egress** — the `*.env` per service.

> **Key result:** the intra-fleet gRPC mesh is **tiny** — only **6 services** receive
> calls from another fleet service. The rest is Kafka (egress to MSK, not pod→pod)
> or client-facing. That makes ingress micro-segmentation low-risk; egress lockdown
> is the harder half (managed AWS ENIs).

---

## 1. gRPC server ports

| Port | Service | Role |
|---|---|---|
| 50051 | chat | client-facing |
| 50052 | profile | **mesh callee** |
| 50053 | social-graph | **mesh callee** |
| 50054 | geo-discovery | client-facing |
| 50055 | notification | client-facing |
| 50056 | post | **mesh callee** |
| 50057 | comment | client-facing |
| 50058 | engagement | client-facing |
| 50059 | account | **mesh callee** |
| 50060 | auth | **mesh callee** (JWKS) |
| 50070 | timeline | client-facing (read) |
| 50061 | moderation | **mesh callee** (Screen) |
| 50062 | search | client-facing (read) |
| 50063 | media | client-facing |
| 50064 | counter-server | client-facing (read) |
| 50065 | counter-worker | worker (health only) |
| 50066 / 8443 | realtime-gateway | internal health / **public WSS** |
| 50067 | realtime-dispatcher | worker (health only) |
| 50068 | audit-server | TIER-0 (break-glass RecordPrivileged + Query) |
| 50069 | audit-worker | worker (health only) |
| 50072 | wallet | **mesh callee** (TIER-0 ledger) + client-facing |

> ✅ **Resolved (side-finding):** `auth` and `timeline` previously both listened on
> `50060`. Distinct ClusterIPs so it worked, but it broke the one-port-per-service
> convention — `timeline` moved to **50070** (it has no in-fleet caller, so nothing
> dialed it). auth keeps 50060.

---

## 2. Inbound gRPC mesh (the complete set — 6 edges)

The only `*Client` types instantiated anywhere in `crates/services/*`:

| Caller | Client type | → Callee : port | Purpose |
|---|---|---|---|
| `auth` | `AccountServiceClient` | `account:50059` | account lookup during issuance |
| `moderation` | `AccountServiceClient` | `account:50059` | subject resolution |
| `moderation` | `PostServiceClient` + `CommentServiceClient` + `ProfileServiceClient` | `post:50056`, `comment:50057`, `profile:50052` | client report target → owning account (`SubmitReport`) |
| `counter` | `SocialGraphServiceClient` | `social-graph:50053` | follower/following reconcile |
| `timeline` | `SocialGraphServiceClient` / `SocialGraphGrpcClient` | `social-graph:50053` | fan-out + cold rebuild; discovery-feed audience check (`CheckAccess`) — **fail closed** |
| `timeline` | `GeoDiscoveryServiceClient` | `geo-discovery:50054` | discovery feed NEARBY candidates (`QueryTile`) |
| `search` | `PostServiceClient` | `post:50056` | hydrate post docs |
| `search` | `ProfileServiceClient` | `profile:50052` | hydrate profile docs |
| `search` | `SocialGraphServiceClient` | `social-graph:50053` | query-path audience filter (`CheckAccess`) — degrades to hashtags only when unreachable |
| `geo-discovery` | `SocialGraphServiceClient` | `social-graph:50053` | per-reader map filter (`CheckAccess`) — **fail closed** |
| `post` | `SocialGraphServiceClient` | `social-graph:50053` | audience check (`CheckAccess`) on non-author reads — **fail closed** |
| `comment` | `PostServiceClient` + `SocialGraphServiceClient` | `post:50056`, `social-graph:50053` | read gate (`GetPost` + `CheckAccess`) on non-mesh reads — **fail closed** |
| `media` | `ModerationServiceClient` | `moderation:50061` | **fail-closed Screen gate** |
| `realtime` | `JwksClient` | `auth:50060` | fetch JWKS to verify edge tokens |
| `chat` | `SocialGraphServiceClient` | `social-graph:50053` | `CheckInteraction(MESSAGE)` for direct messages and group invitations — **fail closed** |
| `engagement` | `PostServiceClient` | `post:50056` | hidden like counts (`BatchGetLikeVisibility`) — **fail closed** (likes withheld) |
| `counter-server` | `PostServiceClient` | `post:50056` | hidden like counts on `BatchGetCounters` — **fail closed** |
| `notification` | `ProfileServiceClient` | `profile:50052` | the sender's name in push alerts |
| `account` | `ProfileServiceClient` + `SocialGraphServiceClient` | `profile:50052`, `social-graph:50053` | `FindProfilesByContacts` (address-book matching); GDPR export |
| `account` | post, comment, engagement, chat, media, search clients | `post:50056`, `comment:50057`, `engagement:50058`, `chat:50051`, `media:50063`, `search:50062` | GDPR data export pass (off until `ACCOUNT_EXPORT_BUCKET` is set) |
| `account` | `ModerationServiceClient` | `moderation:50061` | a supervised teen's reports for their supervisor (`ListReportsByReporter`) |
| `wallet` | post, comment, social-graph clients | `post:50056`, `comment:50057`, `social-graph:50053` | a like (`Stake`) checks its target exists and is visible to the one who likes |
| `wallet` | `EngagementServiceClient` | `engagement:50058` | stake settlement (`GetLikePositions`, shadow mode) |
| `geo-discovery`, `account` | `WalletServiceClient` | `wallet:50072` | country unlocks (`GetWallet`, `SpendGems`); GDPR export (`wallet.json`) |

### Inbound matrix (who a policy must allow)

| Callee | Allowed in-mesh callers | Port |
|---|---|---|
| `account` | `auth`, `moderation`, `geo-discovery` (country unlocks: home country) | 50059 |
| `social-graph` | `counter`, `timeline`, `post`, `comment`, `search`, `geo-discovery`, `chat`, `account`, `wallet` | 50053 |
| `post` | `search`, `comment`, `moderation`, `engagement`, `counter-server`, `account`, `wallet` | 50056 |
| `profile` | `search`, `auth` (owned profiles → the edge token's `pids` claim), `moderation` (report target → account), `account`, `notification` | 50052 |
| `moderation` | `media`, `account` | 50061 |
| `auth` | `realtime` | 50060 |
| `wallet` | `geo-discovery`, `account` **only** (`SpendGems` has no caller gate yet, backend#852) | 50072 |
| `auth` (JWKS, HTTP) | **every server pod** — all edge-token verifiers | 8081 |

`comment` takes one in-mesh caller, `moderation` (report target lookup), on 50057,
and `geo-discovery` one, `timeline` (NEARBY), on 50054: both are still in the
same-namespace allow, not tightened.

**No in-mesh inbound at all** (→ ingress = health probe only, + the **client
edge** on :9443, §3): `chat`, `notification`,
`engagement`, `timeline`, `search`, `media`, `counter-server`, and the workers
`counter-worker`, `realtime-dispatcher`, `audit-worker`. `audit-server` takes only
the break-glass `RecordPrivileged`/`Query` path (no normal-flow mesh caller).
`realtime-gateway` takes public WSS on 8443 (already allowed in #519).

---

## 3. ✅ Decision — client entry point: ALB → per-service **edge listener** (:9443)

**Implemented 2026-09-15.** Every client-facing server runs a second, dedicated
gRPC listener — the **client edge** (`GRPC_EDGE_ADDR`, `:9443` fleet-wide) — that
one internet-facing ALB host-routes to (`api-<svc>-<env>.core-platform.click`,
`k8s/overlays/<env>/client-edge-ingress.yaml`). The listener is guarded in-process
by `transport::grpc::edge`:

- **allow-list** — only the RPCs the service declares in `Service::EDGE_POLICY`
  exist on the edge (anything else is `UNIMPLEMENTED`); internal RPCs, staff
  consoles and reflection are mesh-only by construction;
- **authentication** — unless a rule is `public` (only `auth.Login`/`Refresh`),
  the caller presents the ES256 edge token minted by `auth`, verified against
  `auth`'s JWKS (`EDGE_JWKS_URL`, issuer + audience pinned); the client-supplied
  `x-edge-user` header is stripped and re-set from the verified subject, so
  `per_caller` rate limits key on real identities;
- **actor binding** — handlers bind their identity field to the token with
  `require_account` (field is an account id ⇒ must equal `sub`) or
  `require_profile` (field is a profile id ⇒ must be in the token's `pids`, the
  profiles the account owns, read from `profile` at every mint).

The **mesh listener** (`<SVC>_GRPC_ADDR`) is unchanged: no token, NetworkPolicy
scoped as before. NetworkPolicy opens **:9443 only** to the ALB (`allow-client-edge`,
`ipBlock 0.0.0.0/0` like the WSS rule — the ALB ENIs are not pods); the mesh ports
are not reachable from it.

Why a second listener rather than one port with a "trusted internal caller"
bypass: the six mesh edges carry no user token (`search → post`, `timeline →
social-graph`, …), so a single authenticated port would have needed either a
workload identity for every caller (SA tokens / mTLS) or a fail-open IP-based
exemption. A dedicated port makes the property structural — whatever reaches
:9443 is authenticated — with zero change to the mesh callers.

<details>
<summary>Superseded decision (2026-06-29) — keep same-ns until an edge exists</summary>

The "client-facing" services above are read/command APIs meant to be called by a
gateway/BFF, **not** by other fleet services. Evidence as of this decision:

- **No client edge is deployed to staging** — no ALB Ingress (only the realtime
  NLB), and no in-cluster BFF. So these services have **no real in-cluster inbound**
  beyond health probes today.
- The GraphQL BFF (`backend/gateway/graphql-bff`) lived only in the **legacy Bazel
  `backend/` tree** (since deleted) — its image was built/pushed to ECR, but it has
  no k8s manifest in this repo and is not wired to the staging overlay.
- `dev` exposes services via an **ALB → service directly** (per-service
  `api-<svc>.core-platform.click`, gRPC backend, `target-type: ip` — see
  `k8s/overlays/dev/ingress.yaml`), i.e. NOT fronted by the BFF.

**Decision:** keep the client-facing set on the **#519 same-namespace baseline** —
no per-service ingress change. Tightening them now (to health-probes-only) would
break the edge the moment it lands, for no real isolation gain while there is no
edge. The cross-namespace + external isolation from #519 already applies.

**Revisit trigger** — when a client edge is added to staging, pick the matching
ingress source and tighten:

| Edge added | Allow ingress to client-facing services from |
|---|---|
| ALB → service directly (mirror dev) | the VPC / public-subnet **ipBlock** (ALB ENIs), on the svc gRPC port |
| Single in-cluster GraphQL BFF | the **BFF pod label** only (tightest) |

The **6 mesh callees** + **TIER-0/worker** services are already tightened (§2, #521);
this decision only concerns the remaining client-facing set.

</details>

---

## 4. Kafka event plane (egress to MSK, not pod→pod)

From `EVENT_CATALOG.md` — these are producer→consumer over MSK, so they are
**egress to the broker ENIs**, never pod-to-pod ingress. They do NOT need ingress
allows; they inform the **egress** policy (who needs MSK :9096).

| Topic | Producer | Consumers |
|---|---|---|
| `account.v1.events` | account | audit, profile |
| `profile.v1.events` | profile | search, post, social-graph |
| `post.v1.events` | post | timeline, search, realtime |
| `post.published` / `post.deleted` | post | geo-discovery, notification / timeline, geo-discovery |
| `comment.created` / `comment.deleted` | comment | notification, engagement / engagement |
| `engagement.reactions` | engagement | counter, notification, engagement |
| `social-graph.*` (followed/unfollowed/tier) | social-graph | timeline, profile |
| `counter.v1.popularity` | counter | realtime, geo-discovery |
| `moderation.v1.events` | moderation | audit, search, media, post, geo-discovery |
| `auth.v1.events` | auth | audit |
| `media.v1.events` | media | media |
| `chat.*` | chat | chat (rest orphan) |

**MSK producers/consumers** (need egress :9096): account, profile, post, comment,
engagement, social-graph, counter (+worker), moderation, auth, media (+worker), chat,
geo-discovery, notification, timeline, search, realtime (+dispatcher), audit (+worker).
(≈ everyone except the pure read paths.)

---

## 5. Egress map (per service) — for the v2 egress lockdown

Every pod also needs: **DNS** → `kube-system` CoreDNS :53 (UDP/TCP), and **OTel** →
`otel-collector.observability.svc` :4317.

| Service | Datastores / object store (egress) | gRPC callees | Kafka |
|---|---|---|---|
| account | CNPG `account` | profile:50052, social-graph:50053, moderation:50061; GDPR export: post:50056, comment:50057, engagement:50058, chat:50051, media:50063, search:50062, wallet:50072 | producer |
| auth | CNPG `auth`, Redis, **internet** (see below) | account:50059, profile:50052 | producer |
| profile | CNPG, Redis, Scylla | — | both |
| social-graph | CNPG, Redis, Scylla | — | both |
| post | CNPG, Scylla | social-graph:50053 | both |
| comment | CNPG, Scylla | post:50056, social-graph:50053 | both |
| engagement | CNPG, Redis, Scylla | post:50056 | both |
| counter (server+worker) | CNPG, Redis, Scylla | social-graph:50053, post:50056 (server) | both |
| geo-discovery | CNPG, Redis, Scylla | social-graph:50053, wallet:50072, account:50059 | consumer |
| notification | CNPG, Redis, Scylla, **internet** (APNs, see below) | profile:50052 | consumer |
| timeline | CNPG, Redis, Scylla | social-graph:50053, geo-discovery:50054 | consumer |
| chat | CNPG, Redis, Scylla | social-graph:50053 | producer |
| moderation | CNPG, Redis, Scylla | account:50059, post:50056, comment:50057, profile:50052 | both |
| media (server) | CNPG, Redis, **S3** (asset + object-store) | moderation:50061 | both |
| media (worker) | CNPG, Redis, **S3** (renditions) | — | consumer |
| search | **OpenSearch** | post:50056, profile:50052, social-graph:50053 | consumer |
| audit (server+worker) | CNPG, **S3** (WORM/witness), KMS | — | consumer |
| realtime (gateway+dispatcher) | Redis | auth:50060 (JWKS) | consumer |
| wallet | CNPG `wallet` | post:50056, comment:50057, social-graph:50053, engagement:50058 | both |

**auth's external egress** (guest-mode B4, core-platform-infra#12/#13/#14): the
lockdown must keep these open from `auth-server`, or sign-up and sign-in break:
- Sign in with Apple / Google id_token keys, **:443**: `appleid.apple.com`
  (`/auth/keys`) and `www.googleapis.com` (`/oauth2/v3/certs`);
- one-time email codes (SES SMTP), **:587**: `email-smtp.us-east-1.amazonaws.com`.
  A VPC interface endpoint (`com.amazonaws.us-east-1.email-smtp`) keeps it private;
- one-time SMS codes (SNS), **:443**: `sns.us-east-1.amazonaws.com`. A VPC
  interface endpoint for SNS keeps it private.

**notification's external egress** (iOS push, core-platform-infra#39): the lockdown
must keep **:443** open from `notification-server` to `api.push.apple.com`, and to
`api.sandbox.push.apple.com` for development builds. Apple serves APNs from
`17.0.0.0/8`, which an `ipBlock` can name.

**Managed-AWS egress targets** (no pod IP — use ipBlock of the **private-data subnet
CIDRs**): MSK :9096, ElastiCache :6379, OpenSearch :443. **S3** → via the S3 gateway
endpoint (NetworkPolicy can't name a prefix list; allow :443 to the VPC/`0.0.0.0/0`
or rely on the gateway-endpoint route). **Scylla** → `scylla` ns :9042 (namespace
selector). **CNPG** → same-ns :5432 (pod selector `cnpg.io/cluster`).

---

## 6. Proposed policy shape (v2)

Layered on top of the #519 baseline:

**Ingress (do now — fully known):**
- Per mesh callee (`account`, `social-graph`, `post`, `profile`, `moderation`,
  `auth`): replace the broad same-ns allow with an allow **only** from the specific
  caller pods on the specific port (table §2).
- Workers (`counter-worker`, `realtime-dispatcher`, `audit-worker`) and `audit-server`:
  deny all mesh ingress (health probes are node→pod, permitted by the VPC CNI).
- `realtime-gateway`: keep the public-WSS allow (#519); 50066 health only.
- Client-facing set: same-ns on the mesh port, plus the **client edge** (:9443)
  from the ALB (`allow-client-edge`, §3).

**Egress (do after ingress proves stable — riskier):**
- Namespace-wide allow: DNS (kube-system :53), OTel (observability :4317).
- Per service: its datastores (Scylla ns / same-ns CNPG / data-subnet ipBlock for
  ElastiCache+OpenSearch+MSK / S3 :443) + its gRPC callee(s) from §5.
- Flip on `default-deny-egress` **last**, per service, watching for drops.

---

## 7. Decisions

1. ~~**Client entry point**~~ ✅ Implemented 2026-09-15 (§3) — ALB → per-service
   **edge listener** (:9443) with in-process allow-list + edge-token authn.
2. **Egress scope** — *OPEN.* Full egress lockdown now, or ingress-only first?
   (Egress needs the live data-subnet CIDRs + S3 handling; higher breakage risk.)
   This is the only remaining open decision.
3. ~~**Port collision** — fix `auth`/`timeline` both on 50060.~~ ✅ Done — `timeline` → 50070.
4. ~~**CNI** — confirm `enableNetworkPolicy=true` (shipped in #519) is live before any
   of this enforces.~~ ✅ Confirmed: `modules/eks/main.tf` sets it on the vpc-cni addon.

Ingress micro-segmentation is now as tight as the known graph allows (mesh callees
+ TIER-0/workers in #521; the client edge on its own authenticated port per #1).
The only remaining policy work is **egress** (#2). Rollout slots into Phase 3c of
`docs/runbooks/audit-remediation-rollout.md` (apply allows first, deny last, watch).
