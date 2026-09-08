terraform {
  required_providers {
    tencentcloud = {
      source = "tencentcloudstack/tencentcloud"
    }
  }
}

provider "tencentcloud" {
  region     = "ap-shanghai"
  secret_id  = var.tencent_secret_id
  secret_key = var.tencent_secret_key
}

variable "tencent_secret_id" {
  type      = string
  sensitive = true
}

variable "tencent_secret_key" {
  type      = string
  sensitive = true
}

variable "domain" {
  type    = string
  default = "tripbill.cn"
}

# 国内业务入口（腾讯云 Worker，Ingress-Nginx）
resource "tencentcloud_dnspod_record" "root" {
  domain      = var.domain
  sub_domain  = "@"
  record_type = "A"
  record_line = "默认"
  value       = "124.221.136.117"
  ttl         = 600
}

resource "tencentcloud_dnspod_record" "www" {
  domain      = var.domain
  sub_domain  = "www"
  record_type = "A"
  record_line = "默认"
  value       = "124.221.136.117"
  ttl         = 600
}

# 海外测试入口（阿里云法兰克福 Worker，Traefik hostPort）
resource "tencentcloud_dnspod_record" "eu" {
  domain      = var.domain
  sub_domain  = "eu"
  record_type = "A"
  record_line = "默认"
  value       = "8.209.89.31"
  ttl         = 600
}

output "record_ids" {
  value = {
    root   = tencentcloud_dnspod_record.root.id
    www    = tencentcloud_dnspod_record.www.id
    eu     = tencentcloud_dnspod_record.eu.id
  }
}
