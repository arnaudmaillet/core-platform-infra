---
i18n:
  source: ./README.md
  source_sha256: 83451a11363dbae024221eaa03121558962b24d3040600c0e00075dbe3239671
  translated_at: 2026-10-04
  status: complete
---
> 🇫🇷 Traduction française — la version **anglaise** [`README.md`](./README.md) fait foi.
> En cas de divergence, l'anglais prime. Les contrats (codes d'erreur, variables
> d'environnement, noms de topics, signatures, identifiants) sont volontairement
> laissés en anglais.

# `core-platform-infra` — Documentation

**Point d'entrée de la couche plateforme** : provisionnement AWS, cascade GitOps,
mise à l'échelle, acheminement des secrets, création ou destruction d'un environnement.

La documentation de la couche applicative (README des services, ADR, modèle de
domaine, catalogue d'événements, architecture du workspace) se trouve dans
[`core-platform-backend/docs`](https://github.com/arnaudmaillet/core-platform-backend/tree/develop/docs).

## Aiguillage

| Vous voulez… | Lire |
|---|---|
| Comprendre toute la plateforme (vue d'ensemble canonique) | [Guide maître de l'infrastructure](infrastructure/README.fr.md) |
| Opérer ArgoCD, les appsets, le CMP `envsubst`, les sync waves | [GitOps / ArgoCD](infrastructure/gitops-argocd.fr.md) |
| Savoir ce que crée chaque unité Terragrunt et ses dépendances | [Unités Terragrunt](infrastructure/terragrunt-units.fr.md) |
| Acheminer un secret d'AWS jusqu'à un pod | [Topologie des secrets (ESO)](infrastructure/secrets-eso.fr.md) |
| Créer / détruire un environnement | [Cycle de vie des environnements](runbooks/environment-lifecycle.fr.md) |
| Dérouler le rollout complet et ordonné | [Runbook de rollout](runbooks/audit-remediation-rollout.md) |
| Reconstruire le staging jetable | [Reconstruction du staging jetable](runbooks/staging-disposable-rebuild.md) |
| Modifier une NetworkPolicy | [Graphe d'appels des NetworkPolicies](security/network-policy-call-graph.md) |
| Traduire un document | [Guide de traduction](i18n/TRANSLATION.md) |

## Le contrat plateforme / application

Un service ne consomme la plateforme que par : sa configuration via l'environnement
(`<SVC>_GRPC_ADDR`, endpoints des backends), ses secrets via des Secrets k8s montés
(jamais directement depuis AWS), un label de pod `tier:` (fail-open / fail-closed),
et une image par binaire construite par le backend. Tout ce qui concerne *la façon
dont un service est ordonnancé, mis à l'échelle, joint ou alimenté en secrets* se
modifie ici ; tout ce qui concerne *ce qu'il fait* se modifie dans le backend. Un
changement qui touche les deux atterrit ici en premier (voir
[`CLAUDE.md`](../CLAUDE.md) — contrat inter-repos).
