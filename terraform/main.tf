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

# 海外 demo 入口：纯 IP 直连（http://8.209.89.31，Traefik hostPort），不占域名
# eu 子域名预留给小程序业务，如需启用再在此添加 A 记录

output "record_ids" {
  value = {
    root = tencentcloud_dnspod_record.root.id
    www  = tencentcloud_dnspod_record.www.id
  }
}
