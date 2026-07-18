# Namespaces
resource "kubernetes_namespace" "ingress_nginx" {
  metadata {
    name = "ingress-nginx"
  }
}

resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
  }
}


# External Secrets Operator namespace
resource "kubernetes_namespace" "external_secrets" {
  metadata {
    name = "external-secrets"
  }
}
