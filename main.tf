# Policy

locals {
  policy = <<EOT
version: STSv1
mode: ${var.mode}
%{for mx in var.mx~}
mx: ${mx}
%{endfor~}
max_age: ${var.max_age}
EOT
}

# Route 53 records

data "aws_route53_zone" "default" {
  name = var.domain_name
}

resource "aws_route53_record" "default" {
  zone_id = data.aws_route53_zone.default.zone_id
  name    = "mta-sts.${var.domain_name}"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.default.domain_name
    zone_id                = aws_cloudfront_distribution.default.hosted_zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "policy" {
  zone_id = data.aws_route53_zone.default.zone_id
  name    = "_mta-sts.${var.domain_name}"
  type    = "TXT"
  ttl     = 300

  # Checksum is not checked by MTA-STS clients, only used for change detection.
  # Terraform is unlikely to generate two policies with the same MD5 hash.
  records = ["v=STSv1; id=${md5(local.policy)};"]
}

resource "aws_route53_record" "tlsrpt" {
  zone_id = data.aws_route53_zone.default.zone_id
  name    = "_smtp._tls.${var.domain_name}"
  type    = "TXT"
  ttl     = 300

  # Checksum is not checked by MTA-STS clients, only used for change detection.
  # Terraform is unlikely to generate two policies with the same MD5 hash.
  records = ["v=TLSRPTv1; rua=${var.rua}"]
}

# ACM certificate

resource "aws_acm_certificate" "default" {
  domain_name       = "mta-sts.${var.domain_name}"
  validation_method = "DNS"
}

resource "aws_route53_record" "cert_validation" {
  zone_id = data.aws_route53_zone.default.zone_id
  name    = aws_acm_certificate.default.domain_validation_options[0].resource_record_name
  type    = aws_acm_certificate.default.domain_validation_options[0].resource_record_type
  records = [aws_acm_certificate.default.domain_validation_options[0].resource_record_value]
  ttl     = 60
}

resource "aws_acm_certificate_validation" "cert" {
  certificate_arn         = aws_acm_certificate.default.arn
  validation_record_fqdns = [aws_route53_record.cert_validation.fqdn]
}

# Cloudfront distribution

resource "aws_cloudfront_distribution" "default" {
  depends_on = [aws_acm_certificate_validation.cert]
  origin {
    domain_name = aws_s3_bucket.default.bucket_regional_domain_name
    origin_id   = "default"

    s3_origin_config {
      origin_access_identity = aws_cloudfront_origin_access_identity.default.cloudfront_access_identity_path
    }
  }

  enabled         = true
  is_ipv6_enabled = true

  aliases = ["mta-sts.${var.domain_name}"]

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "default"

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "allow-all"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  price_class = "PriceClass_All"

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate.default.arn
    minimum_protocol_version = "TLSv1.2_2018"
    ssl_support_method       = "sni-only"
  }
}

resource "aws_cloudfront_origin_access_identity" "default" {
}

# S3 bucket/file

resource "aws_s3_bucket" "default" {
  bucket = "mta-sts.${var.domain_name}"
}

data "aws_iam_policy_document" "default" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.default.arn}/*"]

    principals {
      type        = "AWS"
      identifiers = [aws_cloudfront_origin_access_identity.default.iam_arn]
    }
  }

  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.default.arn]

    principals {
      type        = "AWS"
      identifiers = [aws_cloudfront_origin_access_identity.default.iam_arn]
    }
  }
}

resource "aws_s3_bucket_policy" "default" {
  bucket = aws_s3_bucket.default.id
  policy = data.aws_iam_policy_document.default.json
}

resource "aws_s3_bucket_object" "default" {
  bucket       = aws_s3_bucket.default.bucket
  key          = ".well-known/mta-sts.txt"
  content      = local.policy
  content_type = "text/plain"
}