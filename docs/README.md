# `core-platform-infra` — Documentation

**Entry point for the platform layer**: provisioning AWS, the GitOps cascade,
scaling, secret plumbing, standing an environment up or tearing it down.

Application-layer documentation (service READMEs, ADRs, domain model, event
catalog, workspace architecture) lives in
[`core-platform-backend/docs`](https://github.com/arnaudmaillet/core-platform-backend/tree/develop/docs).

## Router

| You want to… | Read |
|---|---|
| Understand the whole platform (canonical overview) | [Infrastructure master guide](infrastructure/README.md) |
| Operate ArgoCD, appsets, the `envsubst` CMP, sync waves | [GitOps / ArgoCD](infrastructure/gitops-argocd.md) |
| Know what each Terragrunt unit creates and depends on | [Terragrunt units](infrastructure/terragrunt-units.md) |
| Wire a secret from AWS to a pod | [Secret topology (ESO)](infrastructure/secrets-eso.md) |
| Stand up / tear down an environment | [Environment lifecycle](runbooks/environment-lifecycle.md) |
| Run the full ordered rollout | [Rollout runbook](runbooks/audit-remediation-rollout.md) |
| Rebuild disposable staging | [Disposable staging rebuild](runbooks/staging-disposable-rebuild.md) |
| Change a NetworkPolicy | [NetworkPolicy call graph](security/network-policy-call-graph.md) |
| Translate a doc | [Translation guide](i18n/TRANSLATION.md) |

## The platform / application contract

A service consumes the platform only through: config from env
(`<SVC>_GRPC_ADDR`, backend endpoints), secrets from mounted k8s Secrets (never
from AWS directly), a `tier:` pod label (fail-open / fail-closed), and one image
per binary built by the backend. Anything about *how a service is scheduled,
scaled, reached, or fed secrets* changes here; anything about *what it does*
changes in the backend. A change needing both lands here first (see
[`CLAUDE.md`](../CLAUDE.md) — cross-repo contract).
