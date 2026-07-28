data "aws_route53_zone" "main" {
  name = "qossim005.online."
}

resource "aws_acm_certificate" "documind" {
  domain_name       = "documind.qossim005.online"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.documind.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id = data.aws_route53_zone.main.zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = 60
  records = [each.value.record]
}

resource "aws_acm_certificate_validation" "documind" {
  certificate_arn         = aws_acm_certificate.documind.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

resource "aws_route53_record" "documind" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "documind.qossim005.online"
  type    = "CNAME"
  ttl     = 300
  records = [var.ingress_lb_hostname]
}
