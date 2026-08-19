# DocuMind - Gotchas & Redeploy Notes

Real issues hit building and redeploying this platform, kept as a debugging
record separate from `Walkthrough.md`. If a step in the walkthrough points
here, the "why it broke" and "why the fix works" is below, organized by the
phase it belongs to.

---

## Redeploy order (read this before tearing down and rebuilding)

"Re-run Phases 1-6 in order" undersells it - the walkthrough's phase
numbers are a teaching narrative, not the real dependency graph. A live
redeploy on a reused AWS account surfaced the actual order that works:

1. **Bootstrap + core infra** - Phase 1 as written (`bootstrap/`, then
   `module.vpc` / `module.eks` / `module.rds` / `module.s3` / `module.irsa`).
   `aws eks update-kubeconfig` again afterward - the API endpoint hostname
   changes on a rebuilt cluster.

   If Route53 already has records for this domain from a prior deployment
   (same AWS account, domain never fully torn down), `module.dns` will
   fail with `InvalidChangeBatch: ... already exists` on the cert
   validation CNAME and/or the app CNAME. Don't delete-and-recreate by
   default - ACM reuses the same DNS validation token per domain, so the
   existing validation record is very likely still correct. `terraform
   import` both records into the new state instead:
   ```bash
   terraform import 'module.dns.aws_route53_record.cert_validation["<domain>"]' \
     <zone_id>_<record_name>_CNAME
   terraform import 'module.dns.aws_route53_record.documind' \
     <zone_id>_<domain>_CNAME
   ```
   Then `plan` to confirm no unwanted replacement before applying.

2. **All platform Helm releases, before touching ArgoCD Applications** -
   `ingress-nginx`, `argocd`, `argo-rollouts` (Phase 8), `external-secrets`
   (Phase 10), and `kube-prometheus-stack` (Phase 5) all install CRDs
   (`Rollout`, `ExternalSecret`, `ClusterSecretStore`, `PrometheusRule`)
   that `documind-gitops`'s manifests already reference. ArgoCD's automated
   sync (`prune: true, selfHeal: true`) is all-or-nothing per Application:
   if even one resource in `manifests/backend/` or `manifests/frontend/`
   references a CRD that isn't installed yet, the *entire* Application
   sticks at `OutOfSync`/`Missing` and creates nothing - not even the
   resources that would've worked fine on their own. Apply every platform
   Helm release first:
   ```bash
   terraform apply \
     -target=helm_release.ingress_nginx \
     -target=helm_release.argocd \
     -target=helm_release.argo_rollouts \
     -target=helm_release.external_secrets \
     -target=helm_release.kube_prometheus_stack
   ```
   *Then* apply the ArgoCD `Application` objects (`apps/backend.yaml`,
   `apps/frontend.yaml`). Hold `apps/cluster.yaml` until Kyverno (Phase 9)
   is installed and `apps/agent.yaml` until the agent's RBAC + image exist
   (Phase 11) - same all-or-nothing logic applies to those.

3. **Expect `ImagePullBackOff` immediately after backend/frontend sync** -
   `module.s3`'s ECR repos got recreated empty in step 1, so no images
   exist yet. This is expected, not a bug: trigger each app repo's GitHub
   Actions workflow (an empty commit works fine - `git commit --allow-empty
   -m "chore: redeploy" && git push`) to build, push, and auto-patch the
   image tag into `documind-gitops`. The GitHub OIDC role (Phase 3a) is
   deterministically named per environment, so it doesn't need updating
   across redeploys as long as you're on the same AWS account. Note the
   asymmetry: `documind-agent`'s ECR repo is created manually
   (`aws ecr create-repository`, not Terraform), so unlike backend/frontend
   it *survives* a teardown - its last-pushed image may already be pullable
   even before you touch Phase 11.

4. **DNS/TLS last** - update `module.dns`'s `ingress_lb_hostname` to the
   new NLB's hostname and `apply -target=module.dns`. Reinstall/confirm
   the AWS Load Balancer Controller's `internet-facing` scheme (defaults
   to `internal`).

**Two more that don't fit a single step above:**

- **Applying a module with a narrow `-target=helm_release...`** (e.g. to
  unblock a CRD dependency in a hurry) only creates resources the *target*
  depends on - sibling resources in the same module that nothing
  references get silently skipped. This is exactly how
  `aws_secretsmanager_secret.backend` (see Phase 10 below) got missed on
  a redeploy even though `helm_release.external_secrets` applied cleanly.
  Prefer an untargeted `terraform apply` once you're past the CRD-ordering
  concern in step 2.
- **`kubectl get pods` won't self-heal a `CreateContainerConfigError`**
  pod just because the Secret/ConfigMap it was missing shows up later -
  the pod needs to be deleted so its controller (Deployment/Rollout)
  recreates it against the now-available resource:
  `kubectl delete pod -n documind -l app=<name>`.

---

## Phase 1 - Infrastructure

### Bootstrap drift: deprecated resources + breaking Helm syntax

`bootstrap/` should only ever contain the S3 state bucket - it runs before
the EKS cluster exists, so it has no cluster to talk to. A stray
`kubernetes_namespace`/`helm_release.ingress_nginx` block (a duplicate of
what `environments/dev` already manages) had gotten committed into
`bootstrap/main.tf` under an unrelated commit, and `bootstrap`'s
`required_providers` never pinned `kubernetes`/`helm` the way
`environments/dev/providers.tf` does (`~> 2.38` / `~> 2.17`). Re-running
`terraform init` there months later silently pulled kubernetes provider v3
and helm provider v3 - both breaking changes (`kubernetes_namespace`
deprecated + stricter RFC 1123 name validation on `metadata.name`;
`helm_release`'s `set {}` **block** syntax removed in favor of a
`set = [{ name = ..., value = ... }]` list) - which is what threw
confusing `terraform validate` errors on a redeploy. Fix: keep
`bootstrap/main.tf` to just the state bucket resources, and if any root
module ever needs `kubernetes`/`helm` providers, pin them explicitly
rather than leaving them floating.

### Variable prompts on `-target` applies

Terraform resolves every declared root-module variable before it can plan
at all, even with `-target` and even when the targeted resources don't
use that variable - `grafana_password` (unused until Phase 5) and
`gemini_api_key` (unused until Phase 10) both get prompted for during
Phase 1c's VPC/EKS/RDS/S3/IRSA apply. A placeholder value is fine at that
point; just make sure the real value is set (`TF_VAR_...`) before the
phase that actually consumes it.

### `t3.small` nodes hit EKS's per-node pod ceiling fast, not a CPU/memory limit

A stuck `Pending` pod with `FailedScheduling: 0/N nodes are available: N
Too many pods` is a **pod-density** ceiling, not insufficient compute -
`t3.small`'s ENI/IP allocation caps it at 11 pods per node regardless of
how much CPU/memory is actually free. With 5 nodes running the full
platform stack (ArgoCD, ingress-nginx, the whole kube-prometheus-stack,
Loki+Promtail, External Secrets, Argo Rollouts, Kyverno, plus per-node
DaemonSets - `aws-node`, `kube-proxy`, `ebs-csi-node`, `node-exporter`,
`promtail`, roughly 5 pods of fixed overhead *per node* before any app
workload lands), the cluster sits right at that ceiling - and a canary
rollout's extra pod, or any one-off debug pod, has nowhere to go. Fixed
by threading `node_desired_size`/`node_max_size` from root `variables.tf`
through to `module.eks` (they weren't wired through at all - setting
them only in `terraform.tfvars` was a silent no-op) and bumping both to
6. Confirm the actual reason before assuming capacity, though -
`kubectl describe pod` on the stuck pod's `Events:` section distinguishes
this from the unrelated storage issue below, which produces a different
message (`unbound immediate PersistentVolumeClaims`) despite presenting
identically as a `Pending` pod with `Node: <none>`.

---

## Phase 3 - CI/CD

`StringLike` in the GitHub OIDC trust policy is case-sensitive - repo
names and the policy pattern must match casing exactly, or
`AssumeRoleWithWebIdentity` silently fails auth from Actions.

---

## Phase 6 - Log Aggregation (Loki + Promtail)

### No usable default StorageClass exists on a fresh EKS cluster

`loki-0`'s PVC (`storage-loki-0`) sat `Pending` for 47 hours with
`FailedScheduling: pod has unbound immediate PersistentVolumeClaims` -
easy to mistake for the node-capacity issue above since it also presents
as a `Pending` pod with `Node: <none>`, but scaling nodes does nothing
for it. Root cause: the EBS CSI driver is installed as an EKS *addon*
(`aws_eks_addon.ebs_csi_driver`), which only provides the CSI
provisioner - it does not create a `StorageClass` object. The cluster's
pre-existing `gp2` class targets the legacy in-tree `kubernetes.io/aws-ebs`
provisioner, which was removed from Kubernetes itself around 1.27+ (this
cluster runs 1.31), so it's a zombie object with no controller behind
it, and it's not marked default anyway. Any PVC without an explicit
`storageClassName` (Loki's Helm chart included) has nothing to bind to.
Fixed in `environments/dev/ebs-csi.tf` with a `kubernetes_storage_class`
targeting `ebs.csi.aws.com` directly, `volumeBindingMode:
WaitForFirstConsumer` (required for EBS - volumes are zone-locked, so
binding has to wait until the pod's actually scheduled), marked default
via the `storageclass.kubernetes.io/is-default-class` annotation.

A newly-created default `StorageClass` does **not** retroactively fix a
PVC that's already existed unbound for a while - the PVC's
`spec.storageClassName` does pick up the new class name once one exists
by then (confirmed via `kubectl get pvc ... -o yaml`), but the pod stayed
stuck on the exact same `unbound immediate PersistentVolumeClaims`
scheduler error for another 15+ minutes after the class was created and
correctly attached. `kubectl delete pvc storage-loki-0 -n loki && kubectl
delete pod loki-0 -n loki` (safe for Loki's own transient chunk storage)
let the StatefulSet recreate both fresh, and it bound immediately.

---

## Phase 9 - Kyverno

If `helm repo add kyverno ...` fails against GitHub Pages-hosted repos
with a TLS/HTTP `EOF` error on Helm 3.21.0, downgrade to Helm 3.16.4.

---

## Phase 10 - Secrets (External Secrets Operator)

### `GEMINI_API_KEY` wasn't Terraform-managed

`modules/external-secrets` originally only wrote `DATABASE_URL` and
`JWT_SECRET` into the AWS secret - `GEMINI_API_KEY` had been added by
hand in the first deployment, which meant a full teardown + redeploy
silently lost it and left `documind-backend`'s pods stuck on
`CreateContainerConfigError`. ESO won't partially sync an `ExternalSecret`
- if even one `data[].remoteRef.property` is missing from the source
secret, the whole target K8s Secret never gets created, even for the
properties that *do* resolve. Fixed by adding `gemini_api_key` as a
proper variable through `modules/external-secrets` and `environments/dev`
so it survives every future redeploy.

### Secrets Manager recovery window blocks redeploy

A prior teardown's `aws_secretsmanager_secret.backend` didn't set
`recovery_window_in_days`, so AWS defaulted to a 30-day recovery window on
delete instead of removing it immediately. `CreateSecret` then fails with
`"already scheduled for deletion"` on the next redeploy, since the name
stays reserved for the whole window. Fixed by setting
`recovery_window_in_days = 0` on the resource (fine for a dev/demo secret
that gets recreated repeatedly; a real prod secret should keep the
default). If you hit this before that fix is in place, force it free:
```bash
aws secretsmanager delete-secret --secret-id documind-dev-backend-secrets \
  --force-delete-without-recovery
```

### `ExternalSecret` status can be stale, not broken

`kubectl get externalsecret` showing `SecretSyncedError` can just be a
snapshot from *before* the underlying AWS secret existed - with
`refreshInterval: 1h`, ESO won't automatically retry for up to an hour
otherwise. Force an immediate resync rather than assuming it's a real
config error:
```bash
kubectl annotate externalsecret <name> -n documind force-sync=$(date +%s) --overwrite
```

---

## Phase 11 - The AI Diagnostic Agent

Gemini model naming shifts over time - verify current model availability
with a direct `curl` to `generateContent` before assuming a model name
still valid in `documind-agent`'s code is still valid.

### CI: plain `Deployment`, not a `Rollout`

`documind-agent` is internal-only (`ClusterIP`, no `Ingress`) and runs a
single replica, so unlike backend/frontend it does **not** get an Argo
Rollouts canary strategy - a 25/50/100% staged rollout is meaningless
across one pod. Its `deploy.yml` mirrors backend/frontend's OIDC-auth +
ECR-push + gitops-patch structure exactly, just patching
`manifests/agent/deployment.yaml`'s image tag directly instead of a
`rollout.yaml`.

### GitHub's OIDC `sub` claim isn't a stable format across repos

Newly created (or newly opted-in) GitHub repos can emit an "immutable
ID" subject claim -
`repo:qezman@72203178/documind-agent@1328824329:ref:refs/heads/main` -
instead of the plain legacy format
`repo:qezman/documind-backend:ref:refs/heads/main` that
`documind-backend`/`documind-frontend` produce. A `StringLike` trust
policy pattern written for the plain format
(`repo:qezman/documind-*:*`) silently fails `AssumeRoleWithWebIdentity`
for any repo using the newer format - no warning, just "Not authorized."
Diagnose by actually decoding the OIDC token GitHub Actions presents
(don't assume its shape):
```yaml
- name: Debug OIDC token claims
  run: |
    TOKEN=$(curl -sSL -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
      "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=sts.amazonaws.com" | jq -r '.value')
    node -e "console.log(JSON.stringify(JSON.parse(Buffer.from(process.argv[1].split('.')[1], 'base64').toString()), null, 2))" "$TOKEN"
```
Two more traps found chasing this:
- AWS hard-requires the trust policy's scoping condition to be on
  `token.actions.githubusercontent.com:sub` or `:job_workflow_ref`
  specifically - no other claim (e.g. the plain `repository` claim,
  which doesn't carry the ID suffix and would otherwise be the obvious
  fix) is accepted; `UpdateAssumeRolePolicy` rejects it outright with
  `MalformedPolicyDocument`.
- `job_workflow_ref` looked like the clean fix (stable format, no ID
  suffix, passes AWS's validation) but empirically did **not**
  authenticate any of the three repos once applied - even though the
  claim value matched the trust policy pattern by hand. Don't trust a
  hand-traced wildcard match over an actual test; when a "should work"
  fix breaks every repo sharing the role, revert rather than debug
  forward.

The durable fix: keep matching on `sub`, but give `StringLike` a list of
patterns (it accepts multiple values per key, OR'd together) so both
claim shapes are covered - the working legacy pattern isn't given up
just because one repo needs a second, ID-aware pattern:
```hcl
StringLike = {
  "token.actions.githubusercontent.com:sub" = [
    "repo:${var.github_org}/documind-*:*",        # legacy sub format
    "repo:${var.github_org}@*/documind-*@*:*",    # immutable-ID sub format
  ]
}
```

### ECR IAM policy resource list needs every repo added explicitly

`aws_iam_role_policy.github_actions`'s `Resource` list was only ever
scoped to `aws_ecr_repository.frontend.arn` and
`.backend.arn` - adding a new app's CI doesn't automatically grant it
ECR push access even once OIDC auth succeeds. Symptom: OIDC assume-role
works fine, then `docker push` fails with `ecr:InitiateLayerUpload ...
no identity-based policy allows`. Since `documind-agent`'s ECR repo was
created manually (see the redeploy-order note above) rather than via
Terraform, bringing it under management hits the same
already-exists-so-import-don't-create pattern as the Route53 records in
Phase 1:
```bash
terraform import module.irsa.aws_ecr_repository.agent documind-agent
```
then add its `aws_ecr_lifecycle_policy` and its ARN to the policy's
`Resource` list like frontend/backend already have.
