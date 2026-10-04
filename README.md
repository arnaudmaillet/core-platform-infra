# core-platform-infra

Infrastructure and GitOps for **core-platform**: Terraform/Terragrunt (AWS — VPC,
EKS + Karpenter, MSK, ElastiCache, OpenSearch, S3, KMS), the ArgoCD bootstrap, and
the Kustomize manifests every environment syncs from.

The application code — the Rust workspace, gRPC contracts, the Kafka
`event-topology` registry and the image builds — lives in
[`core-platform-backend`](https://github.com/arnaudmaillet/core-platform-backend).
This repo deploys its immutable `:<git-sha>` images, pinned here by the backend's
fleet CI.

| Branch | Environment | ArgoCD |
|---|---|---|
| `develop` | staging (active path) | `bootstrap/staging`, `selfHeal` |
| `main` | prod (scaffolded, not applied) | `bootstrap/prod` |

Start with [`docs/README.md`](docs/README.md). Agent/contributor rules: [`CLAUDE.md`](CLAUDE.md).

> History: this repo was split out of the former `core-platform` monorepo on
> 2026-10-04 with full history (`git filter-repo`); `#N` references in older
> commit messages point to `arnaudmaillet/core-platform-backend#N`.
