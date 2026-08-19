# DocuMind - EKS Platform Walkthrough

A step-by-step build order for standing up DocuMind end to end. For the
debugging history and known gotchas behind specific steps, see
[`GOTCHAS.md`](./GOTCHAS.md) - this doc stays to "what to run, what to
expect."

---

## Overview & Architecture

DocuMind is a RAG document Q&A application, deployed on a production-style
AWS/EKS platform: Terraform-managed infrastructure, GitOps delivery via
ArgoCD, progressive delivery via Argo Rollouts, policy enforcement via
Kyverno, full observability (Prometheus/Grafana/Loki), OIDC-authenticated
CI/CD, and a standalone AI diagnostic agent.

**Live app:** [https://documind.qossim005.online](https://documind.qossim005.online)

**Repos:**

- `documind-infra` - Terraform
- `documind-gitops` - Kubernetes manifests + ArgoCD Applications
- `documind-backend` - Fastify API
- `documind-frontend` - React/Vite
- `documind-agent` - AI diagnostic agent

**Architecture diagram:**

`[SCREENSHOT - architecture diagram]`

---

## Prerequisites

- AWS account with a dedicated IAM user (`documind-deployer`, `AdministratorAccess`
  for this sandbox account)
- Domain you control, able to change nameservers
- `terraform` >= 1.6, `kubectl`, `helm` >= 3.16, `docker`, `aws` CLI, `pnpm` (via corepack)
- GitHub repos created: `documind-infra`, `documind-gitops`, `documind-backend`,
  `documind-frontend`, `documind-agent`

```bash
aws configure --profile documind
aws sts get-caller-identity --profile documind
```

---

## Phase 1 - Infrastructure (Terraform)

### 1a. Remote state bootstrap

```bash
cd documind-infra/bootstrap
terraform init
terraform apply -var="state_bucket_name=documind-terraform-state-<account-id>"
```

### 1b. Backend + providers (root module)

`backend.tf`:

```hcl
terraform {
  backend "s3" {
    bucket       = "documind-terraform-state-<account-id>"
    key          = "dev/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
```

`providers.tf` - `aws`, `kubernetes`, `helm` providers. The `kubernetes`/`helm`
providers use **exec-based auth** (`aws eks get-token`), not a static token -
static tokens expire mid-apply on long-running Helm installs.

### 1c. VPC, EKS, RDS, S3, IRSA

```bash
export TF_VAR_db_password="..."
export TF_VAR_database_url="placeholder"
export TF_VAR_jwt_secret="placeholder"
export TF_VAR_gemini_api_key="placeholder"   # real value needed by Phase 10

terraform apply -target=module.vpc -target=module.eks -target=module.rds \
  -target=module.s3 -target=module.irsa
```

- VPC: 2 public + 2 private subnets, NAT Gateway, correctly tagged for EKS
  (`kubernetes.io/role/elb` / `internal-elb`)
- EKS: separate IAM roles for control plane vs. node group
- RDS: security group restricted to EKS node SG only, never public
- S3: private, presigned-URL access only
- IRSA: one scoped IAM role per AWS-calling component

```bash
aws eks update-kubeconfig --profile documind --region us-east-1 --name documind-dev
kubectl get nodes
```

`[SCREENSHOT - kubectl get nodes, all Ready]`
`[SCREENSHOT - terraform apply output / resource count]`

---

## Phase 2 - GitOps (ArgoCD)

### 2a. Install ArgoCD + ingress-nginx (via Terraform/Helm)

```bash
terraform apply -target=helm_release.argocd -target=helm_release.ingress_nginx
kubectl get pods -n argocd -n ingress-nginx
```

### 2b. `documind-gitops` repo structure

```
apps/                  ← ArgoCD Application objects
manifests/
  backend/
  frontend/
  cluster/
  agent/
```

Namespace ownership split: **Terraform owns platform namespaces**
(`argocd`, `ingress-nginx`, `monitoring`, etc.); **GitOps owns the app
namespace** (`documind`), created via `manifests/frontend/namespace.yaml`.

### 2c. First ArgoCD Applications

```yaml
# apps/backend.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: { name: documind-backend, namespace: argocd }
spec:
  project: default
  source:
    {
      repoURL: https://github.com/qezman/documind-gitops.git,
      targetRevision: main,
      path: manifests/backend,
    }
  destination: { server: https://kubernetes.default.svc, namespace: documind }
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: ["CreateNamespace=true"]
```

```bash
git push
kubectl apply -f apps/backend.yaml
kubectl apply -f apps/frontend.yaml
kubectl get application -n argocd
```

Hold off on `apps/cluster.yaml` and `apps/agent.yaml` until Phase 9 and
Phase 11 respectively - see `GOTCHAS.md`.

`[SCREENSHOT - ArgoCD dashboard, Applications Synced/Healthy]`
`[SCREENSHOT - ArgoCD resource tree for documind-backend]`

### 2d. Database migrations

RDS has no schema on a fresh apply. Run once a `documind-backend` pod is
`Running` (it already has `DATABASE_URL` injected) - copy the two SQL
files in and run them through the pod's own `pg` dependency, no local
network path to RDS needed (it's private, EKS-node-only):

```bash
kubectl cp documind-backend/prisma/000_users.sql documind/<backend-pod>:/tmp/000_users.sql
kubectl cp documind-backend/prisma/001_documind.sql documind/<backend-pod>:/tmp/001_documind.sql

kubectl exec -n documind <backend-pod> -- node -e "
const { Pool } = require('pg');
const fs = require('fs');
const pool = new Pool({ connectionString: process.env.DATABASE_URL, ssl: { rejectUnauthorized: false } });
(async () => {
  const client = await pool.connect();
  for (const f of ['/tmp/000_users.sql', '/tmp/001_documind.sql']) {
    console.log('Running', f);
    await client.query(fs.readFileSync(f, 'utf8'));
  }
  console.log('done');
  client.release();
  process.exit(0);
})().catch(e => { console.error(e); process.exit(1); });
"
```

`[SCREENSHOT - signup working on the live app]`

---

## Phase 3 - CI/CD Pipeline

### 3a. GitHub OIDC provider + role (Terraform)

```hcl
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

resource "aws_iam_role" "github_actions" {
  assume_role_policy = jsonencode({
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
        StringLike   = { "token.actions.githubusercontent.com:sub" = "repo:<org>/documind-*:*" }
      }
    }]
  })
}
```

### 3b. Workflow (`.github/workflows/deploy.yml`, each app repo)

```yaml
permissions: { id-token: write, contents: read }
jobs:
  build-and-push:
    steps:
      - uses: actions/checkout@v4
      - uses: aws-actions/configure-aws-credentials@v4
        with: { role-to-assume: arn:aws:iam::<account-id>:role/documind-dev-github-actions-role, aws-region: us-east-1 }
      - uses: aws-actions/amazon-ecr-login@v2
        id: ecr-login
      - run: |
          docker build -t ${{ steps.ecr-login.outputs.registry }}/documind-backend:${{ github.sha }} .
          docker push ${{ steps.ecr-login.outputs.registry }}/documind-backend:${{ github.sha }}
      - uses: actions/checkout@v4
        with: { repository: <org>/documind-gitops, token: ${{ secrets.GITOPS_REPO_TOKEN }}, path: gitops }
      - run: |
          cd gitops
          sed -i "s|documind-backend:.*|documind-backend:${{ github.sha }}|" manifests/backend/rollout.yaml
          git config user.name "github-actions" && git config user.email "actions@github.com"
          git add manifests/backend/rollout.yaml
          git commit -m "chore: deploy backend ${{ github.sha }}" && git push
```

`GITOPS_REPO_TOKEN` - GitHub PAT with write access to `documind-gitops`,
added as a repo secret.

Push to `main` → build → ECR → gitops patch → ArgoCD sync → Rollout canary.

`[SCREENSHOT - successful GitHub Actions run]`
`[SCREENSHOT - auto-commit in documind-gitops from CI]`

---

## Phase 4 - DNS + TLS (Route53 + ACM)

### 4a. Hosted zone + nameservers

Create the Route53 hosted zone, point your registrar's nameservers at the
4 AWS-assigned ones.

### 4b. ACM certificate (DNS-validated)

```hcl
resource "aws_acm_certificate" "app" {
  domain_name       = "documind.qossim005.online"
  validation_method = "DNS"
}
# + validation record + aws_acm_certificate_validation
```

### 4c. AWS Load Balancer Controller

The legacy in-tree provisioner cannot attach an ACM cert to an NLB's TLS
listener via annotations. Confirm:

```bash
aws elbv2 describe-listeners --profile documind --load-balancer-arn <arn> --query "Listeners[].Protocol"
```

If `["TCP","TCP"]` instead of `["TCP","TLS"]`, install the dedicated
controller (own IRSA role, `vpcId` passed explicitly):

```hcl
resource "helm_release" "lb_controller" {
  chart = "aws-load-balancer-controller"
  set { name = "vpcId"; value = module.vpc.vpc_id }
  set { name = "clusterName"; value = module.eks.cluster_name }
}
```

Ingress-nginx annotations (modern controller scheme):

```hcl
set { name = "...aws-load-balancer-type"; value = "external" }
set { name = "...aws-load-balancer-nlb-target-type"; value = "ip" }
set { name = "...aws-load-balancer-scheme"; value = "internet-facing" }
set { name = "...aws-load-balancer-ssl-cert"; value = module.dns.certificate_arn }
set { name = "...aws-load-balancer-ssl-ports"; value = "https" }
set { name = "controller.service.targetPorts.https"; value = "http" }
```

### 4d. Point DNS at the NLB

```bash
kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
# update module.dns's ingress_lb_hostname, terraform apply -target=module.dns
curl -vI https://documind.qossim005.online/
```

`[SCREENSHOT - curl showing HTTP/1.1 200 OK + valid TLS]`
`[SCREENSHOT - browser padlock / cert details on the live domain]`

---

## Phase 5 - Observability

### 5a. Prometheus + Grafana + Alertmanager

```hcl
resource "helm_release" "kube_prometheus_stack" {
  chart   = "kube-prometheus-stack"
  set { name = "grafana.adminPassword"; value = var.grafana_password }
}
```

### 5b. Custom alert rule

```yaml
# manifests/backend/alerts.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: documind-backend-alerts
  namespace: monitoring
  labels:
    release: kube-prometheus-stack # required or the Operator ignores it
spec:
  groups:
    - name: documind-backend
      rules:
        - alert: BackendDown
          expr: kube_deployment_status_replicas_available{deployment="documind-backend", namespace="documind"} == 0
          for: 2m
```

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
```

`[SCREENSHOT - Grafana dashboard, cluster metrics]`
`[SCREENSHOT - Alertmanager / PrometheusRule listed]`

---

## Phase 6 - Log Aggregation (Loki + Promtail)

### 6a. EBS CSI driver (required first - Loki needs a PVC)

```hcl
resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name             = module.eks.cluster_name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = module.irsa.ebs_csi_driver_role_arn
}
```

### 6b. Loki (single-binary mode) + Promtail

```hcl
values = [<<-YAML
  deploymentMode: SingleBinary
  singleBinary: { replicas: 1 }
  read: { replicas: 0 }
  write: { replicas: 0 }
  backend: { replicas: 0 }
YAML
]
```

```bash
terraform apply
kubectl get pods -n loki
```

`[SCREENSHOT - Grafana Explore, Loki query showing live pod logs]`

---

## Phase 7 - Teardown & Redeployment

### Teardown

```bash
kubectl delete -f documind-gitops/apps/
kubectl delete ingress documind-ingress -n documind
aws elbv2 describe-load-balancers --profile documind --query "LoadBalancers[].LoadBalancerName"

aws ecr list-images --profile documind --repository-name documind-backend --query "imageIds[*]" --output json > /tmp/i.json
aws ecr batch-delete-image --profile documind --repository-name documind-backend --image-ids file:///tmp/i.json
aws s3 rm s3://documind-dev-documents-<account-id> --recursive --profile documind

cd documind-infra/environments/dev
terraform destroy
```

If it errors on a dangling Elastic IP blocking IGW detachment:

```bash
aws ec2 describe-addresses --profile documind --filters "Name=domain,Values=vpc" --query "Addresses[].AllocationId"
aws ec2 release-address --profile documind --allocation-id <id>
terraform destroy   # re-run
```

**Verify nothing billable remains:**

```bash
aws eks list-clusters --profile documind
aws rds describe-db-instances --profile documind --query "DBInstances[].DBInstanceIdentifier"
aws ec2 describe-nat-gateways --profile documind --filter "Name=state,Values=available"
```

### Redeployment

The real order, not just "re-run the phases" - see `GOTCHAS.md` for why
each step is ordered this way:

1. Phase 1 (bootstrap → VPC/EKS/RDS/S3/IRSA), then `aws eks
update-kubeconfig` again.
2. Apply **all** platform Helm releases together, before any ArgoCD
   `Application`:
   ```bash
   terraform apply \
     -target=helm_release.ingress_nginx \
     -target=helm_release.argocd \
     -target=helm_release.argo_rollouts \
     -target=helm_release.external_secrets \
     -target=helm_release.kube_prometheus_stack
   kubectl apply -f documind-gitops/apps/backend.yaml
   kubectl apply -f documind-gitops/apps/frontend.yaml
   ```
3. Trigger CI/CD on `documind-backend` and `documind-frontend` to
   populate the (freshly empty) ECR repos:
   ```bash
   git commit --allow-empty -m "chore: redeploy" && git push origin main
   ```
4. Update `module.dns`'s `ingress_lb_hostname` to the new NLB and
   `terraform apply -target=module.dns` last.
5. Continue with Phases 8-11 as written.

`[SCREENSHOT - clean terraform destroy output]`

---

## Phase 8 - Progressive Delivery (Argo Rollouts)

```bash
terraform apply -target=helm_release.argo_rollouts
```

```yaml
# manifests/backend/rollout.yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata: { name: documind-backend, namespace: documind }
spec:
  replicas: 2
  strategy:
    canary:
      steps:
        - setWeight: 25
        - pause: { duration: 30s }
        - setWeight: 50
        - pause: { duration: 30s }
        - setWeight: 100
```

```bash
kubectl get rollout documind-backend -n documind -w
```

`[SCREENSHOT - kubectl argo rollouts get rollout, mid-canary]`

---

## Phase 9 - Policy Enforcement (Kyverno)

```bash
helm repo add kyverno https://kyverno.github.io/kyverno && helm repo update
```

```hcl
resource "helm_release" "kyverno" {
  chart = "kyverno"
  set { name = "reportsController.enabled"; value = "true" }  # keep true - disabling hangs the upgrade hook
}
```

```yaml
# manifests/cluster/policy-disallow-root.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata: { name: disallow-root-user }
spec:
  validationFailureAction: Audit
  rules:
    - name: check-runasnonroot
      match: { any: [{ resources: { kinds: ["Pod"] } }] }
      validate:
        pattern:
          { spec: { "=(securityContext)": { "=(runAsNonRoot)": "true" } } }
```

```bash
kubectl apply -f manifests/cluster/policy-disallow-root.yaml
kubectl apply -f manifests/cluster/policy-restrict-registries.yaml
kubectl get clusterpolicy
```

Once Kyverno's running, sync the cluster-policy ArgoCD app too:

```bash
kubectl apply -f documind-gitops/apps/cluster.yaml
```

`[SCREENSHOT - kubectl get clusterpolicy, both Ready]`

---

## Phase 10 - Secrets Migration (External Secrets Operator)

### 10a. Install + IRSA role + AWS secret

```hcl
resource "helm_release" "external_secrets" {
  chart = "external-secrets"
}
```

`modules/external-secrets` also creates the AWS Secrets Manager secret
(`aws_secretsmanager_secret.backend` / `_version.backend`) that 10b's
`ExternalSecret` pulls from, and the IAM policy letting the ESO role read
it, from `TF_VAR_database_url`, `TF_VAR_jwt_secret`, and
`TF_VAR_gemini_api_key`.

### 10b. `ClusterSecretStore` + `ExternalSecret`

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata: { name: aws-secrets-manager }
spec:
  provider:
    aws:
      service: SecretsManager
      region: us-east-1
      auth:
        jwt:
          serviceAccountRef:
            { name: external-secrets, namespace: external-secrets }
```

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata: { name: documind-backend-secrets, namespace: documind }
spec:
  refreshInterval: 1h
  secretStoreRef: { name: aws-secrets-manager, kind: ClusterSecretStore }
  target: { name: documind-backend-secrets, creationPolicy: Owner }
  data:
    - secretKey: DATABASE_URL
      remoteRef: { key: documind-dev-backend-secrets, property: DATABASE_URL }
    - secretKey: JWT_SECRET
      remoteRef: { key: documind-dev-backend-secrets, property: JWT_SECRET }
    - secretKey: GEMINI_API_KEY
      remoteRef: { key: documind-dev-backend-secrets, property: GEMINI_API_KEY }
```

```bash
kubectl get clustersecretstore
kubectl get externalsecret -n documind
kubectl get secret documind-backend-secrets -n documind
```

`[SCREENSHOT - ExternalSecret SecretSynced=True]`

---

## Phase 11 - The AI Diagnostic Agent (`documind-agent`)

Standalone service. Gemini function-calling decides which real, read-only
`kubectl`/Loki tools to call for a given question.

### 11a. RBAC (dedicated, read-only)

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: { name: agent-readonly, namespace: documind }
rules:
  - apiGroups: [""]
    resources: ["pods", "pods/log"]
    verbs: ["get", "list"]
```

### 11b. Build + deploy (CI, same pattern as backend/frontend)

`documind-agent` is internal-only (`ClusterIP`, no `Ingress`, single
replica), so it deploys as a plain `Deployment` - no Argo Rollouts canary,
that's only for backend/frontend's user-facing traffic.

```bash
aws ecr create-repository --profile documind --repository-name documind-agent
```

`.github/workflows/deploy.yml` mirrors backend/frontend exactly: OIDC
auth via `documind-dev-github-actions-role`, build + push tagged by
commit SHA, then auto-patch the tag into
`manifests/agent/deployment.yaml` and commit to `documind-gitops`. Push
to `main` to trigger it, then:

```bash
kubectl apply -f apps/agent.yaml
```

### 11c. Test

```bash
kubectl port-forward -n documind svc/documind-agent 3003:3003
curl -X POST http://localhost:3003/diagnose -H "Content-Type: application/json" \
  -d '{"question": "are all the documind pods healthy right now?"}'
```

`[SCREENSHOT - agent diagnosing a real issue]`
`[SCREENSHOT - kubectl get pods -n documind, agent Running with scoped RBAC]`
