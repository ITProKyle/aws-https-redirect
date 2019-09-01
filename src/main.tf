# Backend setup
terraform {
  backend "s3" {
    key = "https_redirect.tfstate"
  }
  required_version = ">= 0.11"
}

variable "region" {
  type = "string"
  description = "AWS region where most resources will reside."
  default = "us-east-1"
}

variable "route53_domain" {
  type = "string"
  description = "The registered domain name in Route 53. Note: 'from_fqdn' sould be a member of this domain."
}

variable "from_fqdn" {
  type = "string"
  description = "The FROM FQDN. This will be used as the name of the S3 bucket."
}

variable "to_fqdn" {
  type = "string"
  description = "The FQDN to redirect TO."
}

variable "force_destroy" {
  type = "string"
  description = "The force_destroy argument of the S3 bucket"
  default = "false"
}

variable "refer_secret" {
  type = "string"
  description = "A secret string to authenticate CF requests to S3. (its not really a secret)"
  default = "REDIRECT-ME"
}

variable "web_acl_id" {
  type        = "string"
  description = "(optional) WAF Web ACL ID to attach to the CloudFront distribution."
  default     = ""
}

variable "tags" {
  type        = "map"
  description = "Tags"
  default     = {}
}

# AWS Region for Cloudfront (ACM certs only support us-east-1)
provider "aws" {
  version = "~> 2.0"
  region = "us-east-1"
  alias = "cloudfront"
}

# AWS region for everything else
provider "aws" {
  version = "~> 2.0"
  region = "${var.region}"
  alias = "main"
}


# S3 bucket and policy used for the redirect
resource "aws_s3_bucket" "main" {
  provider = "aws.main"
  bucket  = "${var.from_fqdn}"
  acl = "private"
  policy = "${data.aws_iam_policy_document.bucket_policy.json}"
  website {
    redirect_all_requests_to = "${var.to_fqdn}"
  }
  force_destroy = "${var.force_destroy}"
  tags = "${var.tags}"
}

data "aws_iam_policy_document" "bucket_policy" {
  provider = "aws.main"

  statement {
    sid = "AllowCFOriginAccess"
    actions = [
      "s3:GetObject"
    ]
    resources = [
      "arn:aws:s3:::${var.from_fqdn}/*",
    ]
    condition {
      test = "StringEquals"
      variable = "aws:UserAgent"
      values = [
        "${var.refer_secret}"
      ]
    }
    principals {
      type = "*"
      identifiers = ["*"]
    }
  }
}


# ACM cert creation
data "aws_route53_zone" "main" {
  provider     = "aws.main"
  name         = "${var.route53_domain}"
  private_zone = false
}

resource "aws_acm_certificate" "cert" {
  provider = "aws.cloudfront"
  domain_name = "${var.from_fqdn}"
  validation_method = "DNS"
}

resource "aws_route53_record" "cert_validation" {
  provider = "aws.cloudfront"
  name = "${aws_acm_certificate.cert.domain_validation_options.0.resource_record_name}"
  type = "${aws_acm_certificate.cert.domain_validation_options.0.resource_record_type}"
  zone_id = "${data.aws_route53_zone.main.id}"
  records = ["${aws_acm_certificate.cert.domain_validation_options.0.resource_record_value}"]
  ttl = 60
}

resource "aws_acm_certificate_validation" "cert" {
  provider = "aws.cloudfront"
  certificate_arn = "${aws_acm_certificate.cert.arn}"
  validation_record_fqdns = ["${aws_route53_record.cert_validation.fqdn}"]
}


# CloudFront distrobution to handle HTTPS
resource "aws_cloudfront_distribution" "main" {
  provider = "aws.cloudfront"
  http_version = "http2"
  enabled = true
  aliases = ["${var.from_fqdn}"]
  price_class = "PriceClass_100"

  origin {
    origin_id = "origin-${var.from_fqdn}"
    domain_name = "${aws_s3_bucket.main.website_endpoint}"

    # s3_origin_config is not compatible with S3 website hosting, if this
    # is used, /news/index.html will not resolve as /news/.
    custom_origin_config {
      # "HTTP Only: CloudFront uses only HTTP to access the origin."
      # "Important: If your origin is an Amazon S3 bucket configured
      # as a website endpoint, you must choose this option. Amazon S3
      # doesn't support HTTPS connections for website endpoints."
      origin_protocol_policy = "http-only"
      http_port = "80"
      https_port = "443"
      origin_ssl_protocols   = ["TLSv1.2"]
    }

    # custom origin cannot be used to auth to s3. instead we have to use a "secret"
    # in the header. since nothing will be stored in this bucket, its not a security concern.
    # https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-restricting-access-to-s3.html
    custom_header {
      name  = "User-Agent"
      value = "${var.refer_secret}"
    }
  }

  default_cache_behavior {
    target_origin_id = "origin-${var.from_fqdn}"
    allowed_methods = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods = ["GET", "HEAD"]
    compress = true
    viewer_protocol_policy = "allow-all"
    min_ttl = 0
    default_ttl = 300
    max_ttl = 1200

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn = "${aws_acm_certificate_validation.cert.certificate_arn}"
    ssl_support_method = "sni-only"
    minimum_protocol_version = "TLSv1"
  }

  web_acl_id = "${var.web_acl_id}"
}


# Route 53 record for the redirect
resource "aws_route53_record" "web" {
  provider = "aws.main"
  zone_id = "${data.aws_route53_zone.main.zone_id}"
  name = "${var.from_fqdn}"
  type = "A"

  alias {
    name = "${aws_cloudfront_distribution.main.domain_name}"
    zone_id = "${aws_cloudfront_distribution.main.hosted_zone_id}"
    evaluate_target_health = false
  }
}
