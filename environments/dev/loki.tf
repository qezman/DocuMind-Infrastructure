resource "kubernetes_namespace" "loki" {
  metadata {
    name = "loki"
  }
}

resource "helm_release" "loki" {
  name       = "loki"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki"
  namespace  = kubernetes_namespace.loki.metadata[0].name
  version    = "7.2.0"

  values = [<<-YAML
    deploymentMode: SingleBinary
    loki:
      commonConfig:
        replication_factor: 1
      auth_enabled: false
      storage:
        type: filesystem
      schemaConfig:
        configs:
          - from: "2024-01-01"
            store: tsdb
            object_store: filesystem
            schema: v13
            index:
              prefix: loki_index_
              period: 24h
    singleBinary:
      replicas: 1
      resources:
        requests:
          memory: "256Mi"
          cpu: "100m"
        limits:
          memory: "512Mi"
    read:
      replicas: 0
    write:
      replicas: 0
    backend:
      replicas: 0
    lokiCanary:
      enabled: false
    chunksCache:
      enabled: false
    resultsCache:
      enabled: false
    gateway:
      enabled: false
  YAML
  ]

  set {
    name  = "test.enabled"
    value = "false"
  }

  wait       = false
  timeout    = 600
  depends_on = [kubernetes_namespace.loki]
}
