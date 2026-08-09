resource "helm_release" "promtail" {
  name       = "promtail"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "promtail"
  namespace  = kubernetes_namespace.loki.metadata[0].name
  version    = "6.17.1"

  values = [<<-YAML
    config:
      clients:
        - url: http://loki:3100/loki/api/v1/push
    resources:
      requests:
        memory: "64Mi"
        cpu: "50m"
      limits:
        memory: "128Mi"
  YAML
  ]

  wait       = false
  timeout    = 600
  depends_on = [helm_release.loki]
}
