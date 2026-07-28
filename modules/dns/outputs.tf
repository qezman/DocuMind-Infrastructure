output "certificate_arn" {
  value = aws_acm_certificate_validation.documind.certificate_arn
}

output "domain_name" {
  value = aws_route53_record.documind.name
}
