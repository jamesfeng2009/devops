# 国内网络环境 provider 安装配置：
# 优先使用项目内 filesystem_mirror（通过 ghproxy 预下载的二进制），
# 该 provider 排除直连 registry（GitHub 下载超时）。
provider_installation {
  filesystem_mirror {
    path    = "./plugins"
    include = ["registry.terraform.io/tencentcloudstack/tencentcloud"]
  }
  direct {
    exclude = ["registry.terraform.io/tencentcloudstack/tencentcloud"]
  }
}
