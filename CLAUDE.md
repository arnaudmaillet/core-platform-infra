# CLAUDE.md

Guidance for working in `core-platform-infra`. Keep this file short and factual —
it is loaded into every session. Deep detail lives in `docs/` (linked below).

## What this is

The infrastructure + GitOps half of `core-platform`, a hyperscale event-driven
social backend. The **application code** (Rust workspace, gRPC contracts, the
`event-topology` Kafka registry, image builds) lives in
[`arnaudmaillet/core-platform-backend`](https://github.com/arnaudmaillet/core-platform-backend);
this repo only consumes its **immutable images** (`:<git-sha>` on ECR) and its
published contracts.

Infra is Terraform/Terragrunt + EKS + Karpenter + ArgoCD (GitOps via Kustomize).

> `staging` is the active GitOps path (`k8s/overlays/staging`, synced by ArgoCD
> from **this repo's** `develop`). **prod is fully scaffolded but NOT applied**:
> `live/prod` + `k8s/overlays/prod` + `bootstrap/prod` track this repo's `main`
> (merging develop → main is the prod deploy); bring-up prerequisites live in
> `infrastructure/live/prod/env.hcl`.

## Repo layout

| Path | What |
|---|---|
| `infrastructure/modules` + `infrastructure/live/<env>` | Terraform modules + Terragrunt live tree (`root.hcl` = state/provider config) |
| `infrastructure/argocd` | ArgoCD bootstrap appsets + Helm app catalog + Terraform-written `global-params-<env>.json` |
| `k8s/base` + `k8s/overlays/{dev,staging,prod}` | Kustomize manifests (staging is the live fleet) |
| `docs/infrastructure`, `docs/runbooks`, `docs/security` | ops guides, runbooks, NetworkPolicy call graph |
| `tools/k6` | staging soak (k6 operator `TestRun`) |
| `tools/i18n` | translation drift gate (copy of the backend's) |

## Common commands

```bash
kubectl kustomize k8s/overlays/staging            # render (CI renders dev/staging/prod on every PR)
terraform fmt -check -recursive infrastructure    # CI gate
bash tools/i18n/i18n-drift.sh check               # MUST pass (see i18n rule)
# Infra (per env, from infrastructure/live/<env>/us-east-1)
terragrunt run-all plan
```

## Cross-repo contract with the backend

- **Image pins:** the backend's `fleet-images-deploy.yml` builds every binary,
  then its `pin-staging-images` job commits the new `:<git-sha>` tags into
  `k8s/overlays/staging/kustomization.yaml` on this repo's `develop` (deploy key
  `fleet-pin`, the only actor with a ruleset bypass besides admin). Those
  `chore(deploy): pin …` commits are expected — don't fight them, rebase over them.
- **Prod promotion:** `prod-promote.yml` (manual) copies the staging pins onto the
  prod overlay on `develop`; then a develop → main PR here ships prod.
- **Adding a binary / service** (order matters): here first — ECR repo in
  `live/global/artifacts/ecr` **and apply it**, base manifests, the overlays'
  `images:` entry, NetworkPolicy, ServiceAccount; then the backend adds the crate
  and its `FLEET_BINS` entry. A push before the ECR repo exists fails.
- **Coupled change** (new env var, secret, topic consumer): land the infra side
  first with a tolerant default, then the code. Cross-link the two PRs
  (`arnaudmaillet/core-platform-backend#N` ↔ `arnaudmaillet/core-platform-infra#M`).
- **Ports / service registry / error codes / tiers:** owned by the backend
  (`CLAUDE.md` there). Every client-facing server also listens on the edge
  port **9443** behind the ALB.
- **Kafka topics** are provisioned from the backend's `event-topology` registry by
  the `topic-provisioner` PreSync Job (image pinned like the rest) — never add a
  topic by hand here (MSK runs with auto-creation off).

## GitOps / IaC rules

- **ArgoCD tracks `develop` with `selfHeal`.** `develop` is **protected** — branch
  off it, open a PR; don't commit/push to it directly.
- **Apply order matters.** Terraform must run before the workloads sync: the
  staging overlay's runtime endpoints are resolved by an `envsubst` Config
  Management Plugin in `argocd-repo-server` (fed by a Terraform-written Secret), and
  CNPG backups / Karpenter graceful-drain / NetworkPolicies all depend on AWS
  resources Terraform creates. Order: `vpc → eks → data → security → argocd`, then
  let ArgoCD sync. Full sequence: **`docs/runbooks/audit-remediation-rollout.md`**.
- **Terraform state keys are path-derived** (`${path_relative_to_include()}` in
  `infrastructure/root.hcl`). Moving or renaming a unit directory orphans its
  state — use `terragrunt state mv`/a migration, never a plain `git mv`.
- **`kubernetes/argocd` writes back into this repo** (`github_repository_file` →
  `infrastructure/argocd/bootstrap/global-params-<env>.json` on the target
  branch). The repo name is derived from `repository_url`; the local GitHub token
  needs write access here.
- **EKS version:** `modules/eks` pins the Kubernetes minor (1.36). Keep it in EKS
  *standard* support — extended support bills the control plane 6x and ends in a
  forced upgrade. Bumping it means bumping Karpenter (min version per k8s minor)
  and the operator charts with it; see `docs/infrastructure/README.md` §2.2.
- **Image tags:** overlays are pinned to immutable `:<git-sha>` tags by the
  backend's fleet CI. Don't reintroduce floating tags.
- **Kustomize CRD references:** the built-in nameReference transformer doesn't know
  KEDA `ScaledObject.scaleTargetRef` or CNPG `ScheduledBackup.spec.cluster.name` —
  overlays add `configurations:` entries (`*-refs-config.yaml`) so `namePrefix`
  flows. Add one when introducing a CRD that references another resource by name.
- **Service tiers** are a runtime contract (pod label `tier:`): TIER-0 =
  fail-closed (`auth`, `moderation`, `audit`); TIER-1 = fail-open
  (`counter`, `media`, `search`, `realtime`). Respect the posture in manifests
  (PDBs, probes, scaling).

## i18n rule

English is canonical; French is a co-located `*.fr.md` whose YAML frontmatter
records the SHA-256 of the EN source it was translated from. **If you edit an EN
doc that has a `.fr.md`, update the FR too and re-stamp**
(`bash tools/i18n/i18n-drift.sh stamp <file>.fr.md`), or CI fails. Contracts
(error codes, env vars, topic names, identifiers) stay in English inside FR files.
See `docs/i18n/`.

## Key references

- Docs entry point: `docs/README.md`
- Infra & ops overview (canonical): `docs/infrastructure/README.md`
- GitOps / ArgoCD operations: `docs/infrastructure/gitops-argocd.md`
- Terragrunt units reference: `docs/infrastructure/terragrunt-units.md`
- Secret topology (ESO / ClusterSecretStore): `docs/infrastructure/secrets-eso.md`
- Environment lifecycle runbook: `docs/runbooks/environment-lifecycle.md`
- Rollout runbook: `docs/runbooks/audit-remediation-rollout.md`
- NetworkPolicy call graph (W8): `docs/security/network-policy-call-graph.md`
- Event plane (who produces/consumes what): backend `docs/domain/EVENT_CATALOG.md`
