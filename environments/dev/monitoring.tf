# Prometheus + Grafana + Alertmanager, bundled via kube-prometheus-stack.
# Grafana admin password is set via TF_VAR_grafana_password (same
# export-not-tfvars pattern as db_password).
resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
  }
}

resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name
  version    = "87.21.0" # confirm current version before applying

  set {
    name  = "grafana.adminPassword"
    value = var.grafana_password
  }

  # Modest sizing for a dev cluster, same spirit as Kyverno's resource limits
  set {
    name  = "prometheus.prometheusSpec.resources.requests.memory"
    value = "256Mi"
  }
  set {
    name  = "prometheus.prometheusSpec.resources.requests.cpu"
    value = "100m"
  }
  set {
    name  = "prometheus.prometheusSpec.retention"
    value = "3d" # short retention, dev cluster, no need for long history
  }

  wait       = false
  timeout    = 900
  depends_on = [kubernetes_namespace.monitoring]
}
