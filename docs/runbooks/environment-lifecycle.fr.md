---
i18n:
  source: ./environment-lifecycle.md
  source_sha256: 6476a12f22d8344ed4f819531f6f98aea2636a55b1f3df3b14e86d4476fbdc90
  translated_at: 2026-10-10
  status: complete
---
> 🇫🇷 Traduction française — la version **anglaise** [`environment-lifecycle.md`](./environment-lifecycle.md) fait foi.
> En cas de divergence, l'anglais prime. Les contrats (codes d'erreur, variables
> d'environnement, noms de topics, signatures, identifiants) sont volontairement
> laissés en anglais.

# Runbook : Cycle de vie d'un environnement (preflight → provisionnement → validation → démontage → reconstruction)

**Classe de document :** Runbook / Production · **Audience :** ingénieurs DevOps ·
**Environnement :** `staging` (le chemin GitOps live, jetable) · **Complément de :**
le [guide GitOps](../infrastructure/gitops-argocd.md), la
[référence des unités Terragrunt](../infrastructure/terragrunt-units.md), et le
runbook [reconstruction du staging jetable](staging-disposable-rebuild.md).

Staging est un **environnement jetable** : il est monté à partir de zéro, validé, et
démonté de façon répétée. Ce runbook est la boucle de bout en bout et les contraintes
d'ordonnancement qui maintiennent chaque phase sûre. Les deux dangers étroits et bien
connus — l'état de suppression Secrets-Manager/KMS et les fuites de load-balancers/ENI —
ont un outillage dédié que ce runbook déclenche au bon moment.

```
   ┌──────────┐   ┌───────────┐   ┌──────────┐   ┌────────────────────┐
   │ PREFLIGHT│──►│ PROVISION │──►│ VALIDATE │──►│ GRACEFUL TEARDOWN  │──┐
   └──────────┘   └───────────┘   └──────────┘   └────────────────────┘  │
        ▲                                                                 │
        └─────────────────────  REBUILD  ────────────────────────────────┘
```

Définissez ceci une fois par session :

```bash
BASE=infrastructure/live/staging/us-east-1
export AWS_REGION=us-east-1
```

---

## Phase 1 — Preflight (avant chaque apply)

Une reconstruction lancée trop tôt après un démontage entre en collision avec un état
AWS qui survit à `terragrunt destroy`. **Faites toujours le preflight**, même sur un
compte « propre ».

```bash
# Report-only: names still reserved by a prior teardown, orphan KMS keys
bash infrastructure/assets/teardown/preflight-clean-env.sh staging

# If anything is RESERVED, clear it (restore + force-delete to free the name)
bash infrastructure/assets/teardown/preflight-clean-env.sh staging --fix
```

**Ce qu'il vérifie et pourquoi (appris à la dure) :**

- Un secret Secrets Manager en `PendingDeletion` **réserve son nom pour toute la
  fenêtre de récupération**, et `describe-secret` renvoie `NotFound` pour lui — donc
  une vérification naïve « existe-t-il ? » signale le nom comme libre alors qu'il ne
  l'est pas. Le script utilise `list-secrets --include-planned-deletion` pour voir la
  vérité.
- Les modules fixent `recovery_window_in_days = 0` (PR #538) pour que les démontages
  suppriment les secrets immédiatement — mais AWS **réserve encore un nom
  force-supprimé pendant quelques minutes**.
- Les clés **KMS** ont une fenêtre de suppression minimale de 7 jours (pas de
  force-immédiat) ; une reconstruction crée des clés fraîches, donc les clés en attente
  sont un coût orphelin, pas un bloqueur — *sauf* si vous importez un secret périmé dont
  la clé est en attente (`KMSInvalidStateException`).

> **Cooldown :** si `--fix` a nettoyé quoi que ce soit, **attendez ~15 minutes** avant
> la Phase 2, ou `CreateSecret` entrera encore en collision sur le nom tout juste
> libéré. C'est l'échec de reconstruction le plus courant — respectez-le.

L'approfondissement des pièges d'état de suppression et l'alternative import/adopt vit
dans [staging-disposable-rebuild.md](staging-disposable-rebuild.md).

---

## Phase 2 — Provisionnement (Terraform, puis convergence GitOps)

Terraform monte la plateforme ; ArgoCD fait ensuite converger la flotte. Le DAG
d'apply et le détail par unité sont dans la
[référence des unités Terragrunt](../infrastructure/terragrunt-units.md) ; la checklist
de provisionnement complète (placeholders d'endpoints, ScyllaCluster, seeding des
secrets) est dans [`k8s/PROVISIONING-staging.md`](../../k8s/PROVISIONING-staging.md).
La séquence au niveau boucle :

```bash
# 0. Account-global units, once per account (not torn down with the env):
#    global/networking/route53 → global/messaging/{ses-identity,sms} (+ artifacts/ecr);
#    global/networking/route53-wynn-cn → delegate wynn.cn's NS at the registrar →
#    global/web/wynn-cn-aasa (its ACM validation waits on the delegation).
# 1. Terraform: whole tree, in dependency order (vpc → eks → data/* →
#    security/{irsa-roles,waf-edge} → networking/media-cdn → kubernetes/argocd).
#    GITHUB_TOKEN is required —
#    the argocd unit registers the repo with ArgoCD.
( cd $BASE && GITHUB_TOKEN=$(gh auth token) \
    terragrunt run --all apply --non-interactive --backend-bootstrap -- -auto-approve )

# 2. Point kubectl at the fresh cluster
aws eks update-kubeconfig --name <cluster> --region "$AWS_REGION"

# 3. Watch GitOps converge: operators (wave -10) → security/platform (wave -5) → fleet (wave 0)
kubectl -n argocd get applications -w

# 4. Apply the ScyllaCluster CR once scylla-operator is Healthy (un-prefixed FQDN)
kubectl apply -k k8s/base/infra/scylla-cluster
```

**Contraintes d'ordonnancement qui doivent tenir (chacune est un vrai mode de
défaillance) :**

- `security/irsa-roles` s'applique **après** les datastores — elle consomme leurs ARN
  (audit KMS/WORM, buckets media/cnpg). Les `mock_outputs` permettent le `plan`
  antérieur.
- Les opérateurs au **wave −10** doivent être Healthy avant que la flotte de workloads
  (wave 0) n'applique ses CR `ScaledObject`/`Cluster`/`ExternalSecret` — sinon
  `no matches for kind`. Voir
  [GitOps §2](../infrastructure/gitops-argocd.md#2-sync-waves--the-load-bearing-ordering).
- L'unité `kubernetes/argocd` écrit le Secret **`cmp-envsubst-values`** ; sans lui la
  flotte rend des endpoints `${VAR}` littéraux. Relancez cette unité si les
  placeholders ne se résolvent pas.
- `security/waf-edge` s'applique **avant** `kubernetes/argocd`, et les deux avant la
  synchro de la flotte : l'Ingress client-edge porte
  `wafv2-acl-arn: ${WAF_EDGE_ACL_ARN}`. Un `${WAF_EDGE_ACL_ARN}` littéral empêche le
  LB controller de réconcilier l'Ingress : c'est **tout l'ALB client-edge** qui
  casse, pas seulement le WAF.
- `networking/media-cdn` s'applique aussi **avant** `kubernetes/argocd` : media reçoit
  `MEDIA_CLOUDFRONT_DISTRIBUTION_ID` du CMP, et avec un `${…}` littéral chaque purge
  de retrait échoue, donc les retraits sont retentés sans fin. L'unité accorde
  d'abord le droit de purge, puis l'id arrive à media.
- `kubernetes/argocd` doit aussi être ré-appliquée après `eks` (c'est le cas à
  chaque bring-up) : elle écrit `MESH_TOKEN_ISSUER` (l'issuer OIDC d'EKS) dans le
  CMP. Un `${MESH_TOKEN_ISSUER}` littéral sur moderation/wallet fait échouer
  l'issuer de tout appelant mesh : journalisé avec `MESH_CALLER_GATE=log`,
  **refusé** avec `enforce`. Vérifiez l'issuer avant de passer un appelé en
  `enforce` (#62).
- **wallet-server (nouveau service, core-platform-infra#41) :**
  - `global/artifacts/ecr` doit avoir créé `core-platform-wallet-server`, et le
    backend doit avoir ajouté `wallet-server` à `FLEET_BINS`, avec un pin arrivé
    depuis. D'ici là, les deux pods wallet restent en `ImagePullBackOff` et l'App de
    la flotte est Degraded ; le reste de la flotte n'est pas touché.
  - `security/irsa-roles` s'applique avant la synchro de la flotte : la confiance du
    backup CNPG est une liste exacte, et sans `default:<env>-wallet-postgres`
    l'archivage WAL vers S3 échoue.
- **Promotion prod :** lancez `prod-promote` avant tout develop → main. L'overlay
  prod nomme des topics, consumer groups et services (wallet.v1.events,
  counter-stake-aggregator, wallet-server) que seules les images au niveau du pin
  staging (ou après) possèdent.
- **Sandboxes SES / SNS (une fois, par compte, manuel).** Tant que l'accès production
  n'est pas accordé, SES n'envoie qu'aux adresses vérifiées et SNS qu'aux numéros
  vérifiés, ce qui suffit pour les tests staging. Avant l'arrivée de vrais
  utilisateurs, demandez l'accès production SES :
  `aws sesv2 put-account-details --production-access-enabled --mail-type TRANSACTIONAL --website-url <url> --use-case-description "<one-time sign-in codes>" --region us-east-1`,
  puis vérifiez `aws sesv2 get-account --region us-east-1` (`ProductionAccessEnabled`,
  `SendQuota`). DKIM doit afficher `SUCCESS` sur
  `aws sesv2 get-email-identity --email-identity core-platform.click`.
  Pour les SMS, ouvrez un cas de support pour sortir de la **sandbox SMS de SNS**
  *et* relever le **quota de dépenses SMS** (1 USD par défaut) jusqu'au plafond
  mensuel visé, puis relevez `monthly_spend_limit_usd` dans `global/messaging/sms`
  en conséquence. Jamais avant que les contrôles anti-fraude SMS d'auth soient en
  place (core-platform-infra#14).
- **Email d'alerte ops (alarmes de dépenses SMS), gardé hors de ce repo public :**
  `aws ssm put-parameter --name /core-platform/ops/alert-email --type String --value <email> --region us-east-1`,
  ré-appliquez `global/messaging/sms`, puis confirmez l'abonnement depuis la boîte mail.

> **Fiez-vous au Run Summary (`Succeeded / Failed`), PAS au code de sortie** —
> `terragrunt run --all` peut sortir en `0` avec des unités en échec.

---

## Phase 3 — Validation

Confirmez que la plateforme sert réellement avant de déclarer l'environnement monté.

```bash
# Terraform side — zero failed units, endpoints resolvable
( cd $BASE && terragrunt run-all output 2>/dev/null | grep -E 'endpoint|brokers|arn' )

# GitOps side — every App Synced + Healthy
kubectl -n argocd get applications           # no OutOfSync / Degraded
argocd app get staging-fleet                 # the workload App specifically

# Secrets materialized (ESO did its job)
kubectl get externalsecret -A                # all SecretSynced=True
kubectl get secret backend-creds -o jsonpath='{.data}' | jq 'keys'

# Compute & storage plane
kubectl get nodes -l karpenter.sh/nodepool   # Karpenter provisioned nodes
kubectl get storageclass                     # gp3 is default
kubectl get pods -A | grep -vE 'Running|Completed'   # nothing stuck

# Stateful backends
kubectl get clusters.postgresql.cnpg.io -A   # 6 CNPG clusters Healthy
kubectl get scyllaclusters.scylla.scylladb.com -A
```

**Dégradations connues et attendues (pas des échecs) :**

- Le plan WSS de `realtime` échoue en fail-closed (`RTM-1001`) jusqu'à ce que le JWKS
  de `auth` soit joignable — Keycloak est **DEFERRED**, donc c'est attendu. Le plan de
  santé gRPC n'est pas affecté, donc le pod devient quand même Ready.
- `AUTH_KEYCLOAK_CLIENT_SECRET` est un placeholder jusqu'à ce que Keycloak atterrisse.

Si un endpoint placeholder a fuité dans un pod (littéral
`${MSK_BOOTSTRAP_BROKERS_SASL_SCRAM}`), corrigez selon le
[mode de défaillance CMP GitOps](../infrastructure/gitops-argocd.md#34-cmp--envsubst-render-failures-staging-fleet-only).

---

## Phase 4 — Démontage gracieux

**Ne faites jamais `terraform destroy` d'un cluster live à l'aveugle.** Les contrôleurs
in-cluster (AWS LB controller, CNPG, scylla-operator, Karpenter) créent des ressources
AWS que Terraform ne **possède pas** ; un destroy aveugle les fait fuir, et les ENI de
load-balancer résiduelles bloquent le destroy de `aws_vpc` avec `DependencyViolation`.

L'unité `kubernetes/argocd` porte un **`before_hook "graceful_cleanup"` sur `destroy`**
qui exécute `infrastructure/assets/teardown/k8s-graceful-cleanup.sh` automatiquement —
vous lancez simplement le destroy normal :

```bash
( cd $BASE && terragrunt run --all destroy --non-interactive -- -auto-approve )
```

Parce que `destroy` parcourt le DAG en sens inverse, `kubernetes/argocd` est démontée en
premier, déclenchant le hook **avant** que `eks`/`vpc` ne soient touchés. Le hook, dans
l'ordre :

0. **Arrête d'abord tous les réconciliateurs** : met à 0 les contrôleurs application et
   ApplicationSet d'Argo CD (supprimer les appsets ne suffit pas — les apps fleet et
   ScyllaCluster sont des enfants d'app-of-apps et continuaient à s'auto-réparer),
   supprime appsets/apps sans attendre, puis met **Karpenter à 0** pour que rien ne
   re-provisionne de nœuds pour les pods orphelins des étapes suivantes. (Constaté en
   live le 2026-09-15 : avec l'ancien ordre, le selfHeal a recréé le ScyllaCluster,
   12 PVC et le NLB public dans une fenêtre de 3 minutes, et Karpenter a re-provisionné
   4 nœuds pendant que le hook attendait les anciens.)
1. **Supprime les Ingress (ALB) et les Services `type=LoadBalancer` (NLB)**, puis
   **attend (~5 min) qu'AWS les déprovisionne réellement** — `kubectl delete svc`
   retourne avant que le LB controller ait supprimé le vrai NLB/les ENI. Cette attente
   est ce qui prévient la course au `ResourceInUseException` du cert ACM et la fuite
   d'ENI du VPC. Puis supprime tout security group du LB controller resté dans le VPC
   (tag `elbv2.k8s.aws/cluster`) — un orphelin garantit un `DependencyViolation`.
2. **Supprime les CR CNPG/Scylla puis les PVC**, pour qu'`ebs-csi` émette `DeleteVolume`
   (le `reclaimPolicy=Delete` ne se déclenche que sur une suppression ordonnée de PVC),
   **attend que les PV soient récupérés** (le driver CSI part avec le cluster), et
   supprime tout volume EBS taggé au cluster encore `available`.
3. **Termine les instances Karpenter par tag** (`karpenter.sh/nodepool` +
   `kubernetes.io/cluster/<cluster>=owned`, jamais les nœuds MNG) et les attend, puis
   retire les instance profiles IAM par nodeclass que Karpenter ≥ 1.7 crée.
4. **Seconde passe sur les security groups du LB controller**, une fois les ENI des LB
   disparues.

Chaque étape est best-effort (`|| true`) et idempotente — un cluster partiellement cassé
ne doit jamais bloquer le destroy.

### Si le démontage laisse un état périmé (la course ACM)

Si `eks` échoue à supprimer son cert ACM (`ResourceInUseException`) et que `vpc`
sort-tôt, les ressources AWS sont en général parties mais l'*état* de l'unité est
périmé. Réconciliez par unité, puis confirmez zéro fuite :

```bash
( cd $BASE/networking/acm-cert && terragrunt state list )   # inspect first
( cd $BASE/networking/vpc && terragrunt state rm $(cd $BASE/networking/vpc && terragrunt state list) )
aws ec2 describe-vpcs --filters Name=isDefault,Values=false  # expect none (ignore list-flicker; verify by --vpc-ids)
```

L'unité `acm-cert` découplée (PR #543) et l'attente de déprovisionnement des LB rendent
ceci rare.

---

## Phase 5 — Reconstruction

Une reconstruction n'est que la **Phase 1 → Phase 2 → Phase 3** à nouveau. La seule
préoccupation propre à la reconstruction est la dette d'état de suppression que la
Phase 1 nettoie. Si une unité de datastore échoue sur `already scheduled for deletion`
pendant la Phase 2, un nom est encore réservé :

- **Nettoyer (préféré) :** `preflight-clean-env.sh staging --fix`, attendre ~15 min,
  réappliquer.
- **Adopter (pas d'attente, mais MSK-risqué) :** restaurer + `terragrunt import` le
  secret — mais MSK heurte `KMSInvalidStateException` si la clé est en attente ;
  **préférez Nettoyer pour MSK**. Procédure complète dans
  [staging-disposable-rebuild.md](staging-disposable-rebuild.md).

---

## Référence rapide — toute la boucle

```bash
BASE=infrastructure/live/staging/us-east-1 ; export AWS_REGION=us-east-1

# PREFLIGHT
bash infrastructure/assets/teardown/preflight-clean-env.sh staging --fix   # wait ~15m if it cleared anything

# PROVISION
( cd $BASE && GITHUB_TOKEN=$(gh auth token) \
    terragrunt run --all apply --non-interactive --backend-bootstrap -- -auto-approve )
aws eks update-kubeconfig --name <cluster> --region "$AWS_REGION"
kubectl apply -k k8s/base/infra/scylla-cluster

# VALIDATE
kubectl -n argocd get applications ; kubectl get externalsecret -A ; kubectl get nodes -l karpenter.sh/nodepool

# TEARDOWN (graceful hook fires automatically)
( cd $BASE && terragrunt run --all destroy --non-interactive -- -auto-approve )
```

---

## Note sur la frontière

Tout dans ce runbook est **de la couche plateforme** — provisionnement, convergence
GitOps, et démontage cloud. Les développeurs d'application ne lancent jamais ces
commandes ; un service se livre en mergeant sur `develop` et en laissant ArgoCD
synchroniser (voir la
[section frontière du guide GitOps](../infrastructure/gitops-argocd.md#8-what-you-own-vs-what-the-platform-owns)).
