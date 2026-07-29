resource "kubernetes_namespace" "kyverno" {
  metadata {
    name = "kyverno"
  }
}

resource "helm_release" "kyverno" {
  name = "kyverno"
  #   repository = "https://kyverno.github.io/kyverno"

  # chart pulled from local cache, not repo - helm repo add fails against
# github.io-hosted chart repos in this environment
  chart     = "/home/qossim_05/.cache/helm/repository/kyverno-3.2.6.tgz"
  namespace = kubernetes_namespace.kyverno.metadata[0].name
  #   version    = "3.2.6"
  set {
    name  = "replicaCount"
    value = "1"
  }

  set {
    name  = "resource.requests.memory"
    value = "128Mi"
  }

  set {
    name  = "resource.requests.cpu"
    value = "50m"
  }

  set {
    name  = "cleanupController.enabled"
    value = "false"
  }

  set {
    name  = "reportsController.enabled"
    value = "false"
  }

  set {
    name  = "cleanupJobs.admissionReports.enabled"
    value = "false"
  }

  set {
    name  = "cleanupJobs.clusterAdmissionReports.enabled"
    value = "false"
  }

  set {
    name  = "cleanupJobs.clusterEphemeralReports.enabled"
    value = "false"
  }

  set {
    name  = "cleanupJobs.ephemeralReports.enabled"
    value = "false"
  }

  set {
    name  = "cleanupJobs.updateRequests.enabled"
    value = "false"
  }

  wait       = false
  timeout    = 600
  depends_on = [kubernetes_namespace.kyverno]
}
