# nginx-ingress
resource "helm_release" "ingress_nginx" {
  name       = "ingress-nginx"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  namespace  = kubernetes_namespace.ingress_nginx.metadata[0].name
  version    = "4.10.1"

  set {
    name  = "controller.service.type"
    value = "LoadBalancer"
  }


set {
  name  = "controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-type"
  value = "nlb"
}

  # Don't wait for rollout
  wait    = false
  timeout = 600

  depends_on = [kubernetes_namespace.ingress_nginx]
}
