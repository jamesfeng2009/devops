# 多云跨地域 K3s 单Server架构 DevOps 完整落地实施方案\+执行计划

# 一、整体架构总览（最终定型、无坑最优方案）

## 1\.1 机器角色与配置分工（精准匹配硬件负载）

基于三台机器硬件差异、地域差异、负载上限，做固定角色拆分，彻底规避资源过载、跨地域网络问题、集群失控风险：

- **京东云 2C/3.8G 59G（国内·北京）**：K3s 唯一单Server控制节点（纯控制面，零业务混部）
        

    - 承载：集群控制面、系统组件调度中枢、ArgoCD（GitOps）

    - 遗留充电桩业务已全部清理（数据备份于 backups/），整机资源专供控制面

    - 限制：不部署业务Pod、有状态服务、多副本应用，保留控制面污点

- **腾讯云 4C/3.6G 60G（国内·上海）**：纯Worker国内主力业务节点
       

    - 承载：所有国内正式业务、数据库、缓存、前后端项目、多副本应用、Ingress\-Nginx国内流量入口

    - 优势：三台中CPU最强，无控制面开销，是核心业务唯一承载节点

- **阿里云法兰克福 2C/1.8G 40G（海外）**：纯Worker海外测试节点
        
    - 承载：海外访问Demo、极简测试应用、单副本静态项目、Traefik海外流量入口

    - 限制：禁止系统组件、有状态服务、高负载业务、多副本Pod

## 1\.2 核心架构规则（解决所有跨云/跨地域痛点）

1. **控制面架构**：K3s 单Server模式（数据层为内置SQLite，非etcd），放弃跨云高可用，彻底杜绝公网分布式存储脑裂、超时、集群卡死问题，适配跨厂商跨地域网络环境。数据备份通过 `--etcd-snapshot-schedule-cron` 定时快照实现（对SQLite同样生效）。

2. **网络架构**：全局 Wireguard 隧道通信（flannel wireguard\-native 后端），解决跨云节点连通问题。**关键前提**：三台机器分属三个厂商VPC，内网IP互相不可路由，所有节点必须显式配置 `--node-external-ip=<各自公网IP>`，Server额外配置 `--flannel-external-ip`；全节点做MSS clamping规避Wireguard MTU(1420)大包丢包问题。

3. **调度隔离规则**：系统组件强制锁定国内节点，绝不调度至法兰克福；轻重业务分层部署，互不抢占资源。

4. **存储方案**：全节点使用K3s自带 local\-path 本地存储，放弃云厂商CSI（跨云集群天然不支持多厂商CSI混用），适配学习场景。

5. **流量入口方案**：域名DNS托管于DNSPod（腾讯云，保持原有NS不动），A记录直连解析无代理层。国内业务入口=腾讯云Worker上的Ingress\-Nginx（80/443对公网）；海外测试入口=法兰克福Traefik（hostPort）；ArgoCD等管理界面统一走国内Ingress。

6. **资源保护规则**：所有业务Pod强制配置CPU/内存上下限，依托节点污点\+亲和性双重隔离，杜绝集群控制面被业务挤垮。

## 1\.3 全套技术栈分工（标准企业DevOps链路）

- **Terraform**：基础设施IaC，聚焦DNSPod DNS管理（使用DNSPod官方Terraform Provider，域名NS保持在DNSPod无需迁移，零迁移风险；安全组属一次性配置，控制台手动完成更务实）。

- **Ansible**：服务器初始化、环境调优、批量自动化部署K3s集群、节点打标。

- **K3s**：轻量化K8s集群底座，提供容器调度、服务编排核心能力。

- **Helm**：包管理部署集群组件（Ingress\-Nginx、Cert\-Manager、Metrics\-Server、ArgoCD）。

- **Kustomize**：管理自定义业务YAML，实现环境差异化配置、调度规则统一复用。

- **ArgoCD**：实现GitOps全自动持续交付，完成代码提交→自动部署闭环DevOps流程。

# 二、节点标签与调度规范（全局统一、强制落地）

## 2\.1 固定节点标签（集群初始化统一打标）

- 京东云Server：`cloud=jdcloud, region=cn, role=server`

- 腾讯云Worker：`cloud=tencent, region=cn, role=worker`

- 阿里云法兰克福Worker：`cloud=aliyun, region=eu, role=worker`

## 2\.2 强制调度策略（核心避坑规则）

1. **集群系统组件（CoreDNS/Metrics\-Server）**：强制亲和 `region=cn`，仅运行在国内节点，杜绝海外洲际网络延迟导致的集群异常。

2. **国内正式业务**：强制亲和 `cloud=tencent`，全部调度至腾讯云Worker节点，禁止调度海外节点与京东云Server。

3. **海外测试业务**：强制亲和 `region=eu`，仅运行在法兰克福节点，完全隔离国内资源。

4. **京东云Server节点污点管控**：保留默认 `node-role.kubernetes.io/control-plane:NoSchedule` 污点，业务Pod一律不可调度，仅ArgoCD通过显式容忍度部署。

# 三、资源负载管控标准（杜绝过载、适配硬件上限）

## 3\.1 各节点负载阈值（严格执行）

- **京东云Server**：控制面+系统组件+ArgoCD常驻内存约2G（红线70%），CPU峰值出现在ArgoCD同步期（2C可接受）；禁止部署任何业务Pod。

- **腾讯云Worker**：资源富余（4C/3.6G），可承载中小型有状态服务、多副本业务，无严格负载限制（学习场景）。

- **阿里云法兰克福Worker**：仅运行单副本极简测试应用，不叠加任何额外负载。

## 3\.2 通用Pod资源模板（所有业务强制复用）

所有自定义业务必须配置资源上下限，防止单Pod抢占整机资源：

- 常规业务（腾讯云专用）：CPU 200m\-500m、内存256Mi\-512Mi，上限2C/2Gi

- 海外测试业务（法兰克福专用）：CPU 100m、内存128Mi，上限500m/512Mi

- ArgoCD（京东云Server专用）：全组件合计limit上限1.5Gi，关闭Dex、单副本

# 四、网络安全组规范（最小权限、控制台手动管理）

## 4\.1 京东云Server节点入站规则（最小权限）

- 6443/TCP：仅放行腾讯云、阿里云节点IP及本机办公IP（K3s APIServer通信）

- 10250/TCP：仅放行集群节点IP（kubelet节点通信）

- 51820/UDP：放行所有集群节点IP（Wireguard跨云隧道）

- 22/TCP：建议仅放行本地办公IP（SSH远程连接）

- **清理遗留规则**：删除8000/9000/6379/5432/3389等充电桩项目遗留放行；80/443默认关闭（ArgoCD界面统一走腾讯云Ingress入口）

- 禁止业务端口0\.0\.0\.0/0全网放行，杜绝公网扫描、恶意攻击

## 4\.2 Worker节点（腾讯云/阿里云）

- 无集群端口入站需求，全部主动出站连接Server节点

- 腾讯云作为国内业务入口：开放80/443/TCP对公网（Ingress\-Nginx）

- 阿里云作为海外测试入口：开放80/443/TCP对公网（Traefik hostPort）

- 22/TCP：建议仅放行本地办公IP

# 五、分阶段完整落地执行计划（从零到DevOps闭环）

## 阶段零：安全加固与遗留清理 —— 已完成

1. 本地生成专用SSH密钥对，三台服务器安装公钥并逐台验证密钥登录成功。

2. 修改sshd配置禁用密码登录（`PasswordAuthentication no`，root用户 `PermitRootLogin prohibit-password`），重启sshd后二次验证防锁死。

3. 轮换已暴露的明文密码；`.env`移除密码、改用密钥路径引用并加入`.gitignore`，后续Ansible敏感变量用`ansible-vault`加密。

4. 清理京东云遗留充电桩业务（1Panel/Docker/RabbitMQ/PostgreSQL/Redis/auth\-service），数据已备份至本地 `backups/` 目录。

## 阶段一：基础设施标准化（Terraform）—— 已完成

1. 配置Terraform Provider：腾讯云Provider管理DNSPod记录（域名NS保持在DNSPod不动，Cloudflare方案已弃用；GitHub下载provider超时，已通过ghproxy预置filesystem\_mirror，见`terraform/mirror.hcl`）。

2. 已通过Terraform创建A记录并验证生效：`@`/`www`/`argocd` → 腾讯云IP（国内业务入口），`eu` → 阿里云法兰克福IP（海外测试入口），全部直连解析。

3. 三云防火墙已按4.1/4.2规范配置（集群端口6443/51820/10250已放行；遗留清理与SSH收窄待控制台补充）。

## 阶段二：集群自动化部署（Ansible+K3s）—— 已完成

1. 所有节点系统初始化：时间同步、内核调优、安装Wireguard、关闭冗余服务。

2. 京东云节点部署K3s单Server集群：`--node-external-ip --tls-san --flannel-backend=wireguard-native --flannel-external-ip --flannel-iface=eth0 --disable-network-policy`，开启Wireguard隧道、配置公网SAN证书。

3. 腾讯云、阿里云节点以Agent模式加入集群（同样配置 `--node-external-ip=<各自公网IP> --flannel-iface=eth0`），完成跨云集群组网；全节点配置MSS clamping解决MTU问题。

4. 自动为所有节点打标签（2.1规范），配置系统组件固定调度策略。

5. 已同步kubeconfig至本地（`~/.kube/devops-k3s-config`），本地kubectl直连117.72.69.23:6443管理集群。

6. 数据备份已落地：SQLite后端不支持`--etcd-snapshot`（仅etcd生效），已部署`k3s-sqlite-backup.timer`（6小时一次，保留10份）。

### 阶段二踩坑实录（三云轻量机NAT组网关键修正）

1. **京东云HIDS抢占cgroup**：京东云主机安全Agent（jdcloudservice）将cpu/cpuset等v1控制器挂载至`/cgroup/jdcloudhids`，导致cgroup v2下K3s启动报`failed to find cpu cgroup (v2)`。处置：停用并禁用jdcloudservice，`cgroup_no_v1=all`内核参数强制纯v2（代价：京东云主机安全agent失效）。

2. **公网IP为1:1 NAT不绑网卡**：三台轻量机eth0仅内网IP，flannel按node-ip找网卡失败导致Server崩溃循环（`failed to find interface with specified node ip`）。处置：全节点加`--flannel-iface=eth0`强制绑定物理网卡。

3. **内置netpol与NAT不兼容**：网络策略控制器初始化同样按node-ip找网卡，NAT下必然崩溃。处置：Server加`--disable-network-policy`（Wireguard pod网络不受影响，暂无NetworkPolicy能力）。

4. **国内docker.io被墙**：腾讯云/京东云拉取镜像i/o timeout。处置：`/etc/rancher/k3s/registries.yaml`配置镜像加速（腾讯云用`mirror.ccs.tencentyun.com`内网源，京东云用`docker.m.daocloud.io`），已固化进Ansible剧本。

## 阶段三：集群基础组件部署（Helm）—— 半天完成

1. 通过Helm批量部署核心组件：Ingress\-Nginx（亲和 `cloud=tencent`，国内业务入口）、Cert\-Manager、Metrics\-Server。

2. CoreDNS/Metrics\-Server为K3s内置部署（非Helm管理），部署后patch nodeSelector固定至 `region=cn`；svclb/flannel为DaemonSet跑全节点属正常现象，不算违反隔离规则。

3. 配置SSL自动签发、域名路由规则，打通国内业务访问入口。

4. 法兰克福单独启用K3s自带Traefik（单副本+hostPort）作为海外访问入口，海外域名解析至阿里云公网IP，与国内Ingress\-Nginx互不干扰。

### 阶段三执行记录（2026\-09\-08 完成）

1. **Ingress\-Nginx**（Helm 4\.15\.1，hostNetwork 直连腾讯云 80/443，关闭 admission webhook 与 Service）：踩坑两个——① 腾讯云节点公网 IP 注册为 InternalIP，kubelet 探针默认按 PodIP 探测触发 NAT hairpin 超时导致 CrashLoopBackOff，探针需显式 `host: 127.0.0.1`（且 helm upgrade 会丢该字段，需 kubectl SSA 重写）；② hostNetwork 单副本必须 `updateStrategy: Recreate`，否则新旧 Pod 抢占 80/443 端口滚动更新死锁。配置见 `helm/ingress-nginx-values.yaml`。

2. **Cert\-Manager**（Helm，四组件锁定 `cloud=tencent`）+ Let's Encrypt 生产 ClusterIssuer（HTTP\-01 走 ingress\-nginx），`tripbill.cn` 正式证书已签发（tripbill\-cn\-tls，自动续期），Ingress 已启用 TLS 308 跳转。配置见 `k8s/cert-manager/` 与 `k8s/tripjournal/`。

3. **生产服务迁移完成**：PostgreSQL（local\-path PVC）\+ trip\-ledger API \+ Astro 官网均运行于集群，`http(s)://tripbill.cn` 与 `/api/*` 端到端验证通过，宿主机 Caddy 已停用保留回滚。

4. **法兰克福 Traefik**（Helm，hostNetwork hostPort 80/443）：踩坑——K3s containerd `enable_unprivileged_ports=true` 仅对容器独立 netns 生效，hostNetwork Pod 非 root 绑 80/443 仍被拒（且该模式下 capabilities.add 不落入进程 Permitted/Effective 集），修复为节点层 `net.ipv4.ip_unprivileged_port_start=0`（已固化进 `ansible/playbooks/00-init.yml`）。whoami 冒烟测试通过（`k8s/test/50-whoami-eu.yaml`）。

## 阶段四：业务分层部署与隔离（Kustomize）—— 1天完成

1. 基于Kustomize编写统一业务模板，封装节点亲和、资源限制、调度规则。

2. 腾讯云节点部署国内核心业务、有状态服务。

3. 京东云Server节点不部署任何业务（仅系统组件+ArgoCD）。

4. 阿里云法兰克福节点部署海外测试Demo业务。

5. 验证业务完全隔离，无跨云服务调用、无资源抢占。

> **完成记录（2026-09-08）**：落地 `k8s/tripjournal/{base,overlays/cn}` 两层结构——base 放环境无关清单（namespace/postgres/api/web/ingress），cn overlay 注入腾讯云节点亲和（`cloud: tencent`）、Ingress-Nginx 入口类与 LE 证书。旧扁平清单删除、以 kustomize 为唯一配置源；切换用 `kubectl diff -k` 比对后应用，业务零重启。数据库密码等 Secret 手工管理（`secrets/tripjournal-secret.yaml`，不入库），ArgoCD 不接管。

## 阶段五：GitOps闭环搭建（ArgoCD）—— 1天完成

1. Helm部署ArgoCD至**京东云Server节点**（通过显式容忍度调度，全组件资源limit合计≤1.5Gi，关闭Dex、单副本），配置登录权限、走腾讯云Ingress访问入口。

2. 搭建Git仓库，统一托管所有Kustomize业务配置、Helm配置。

3. ArgoCD关联Git仓库，开启自动同步、状态检测。

4. 完成最终DevOps闭环：修改Git配置→集群自动更新→无需手动操作集群。

> **完成记录（2026-09-08）**：本地仓库推送至京东云 git daemon 裸仓库（`/srv/git/devops.git`，systemd 常驻）。踩坑——①京东云节点/Pod 访问 `kubernetes` Service ClusterIP（10.43.0.1:443）超时：kube-proxy 将 Service endpoint DNAT 到公网 IP 触发 1:1 NAT hairpin 阻断，修复为在 nat OUTPUT/PREROUTING 的 KUBE-SERVICES 链**之前**插入 `10.43.0.1:443 → 172.16.0.3:6443` DNAT（服务 `k3s-hairpin-dnat.service` 等待 kube-proxy 就绪后再插规则并持久化）。②argo-cd chart 10.x（ArgoCD v3）已移除 `applicationSet.enabled` 开关，用 `replicas: 0` 缩零。③repo-server 256Mi limit 首次 manifest 生成即 OOMKilled，提至 512Mi（全组件 limit 合计 1.41Gi ≤ 1.5Gi 红线）。ArgoCD 入口：NodePort 30080 直连 IP（http://124.221.136.117:30080，腾讯云防火墙放行后生效）——tripbill.cn 域名系留给小程序业务，devops 不占用子域，原 argocd.tripbill.cn Ingress+TLS+DNS 已下线（Git 删除 → ArgoCD prune 自动清理集群侧，再次验证闭环）。两个 Application（tripjournal / argocd-apps）自动同步双向验证通过：Git 加注解 → 75s 内集群生效，还原 → 自动清除。whoami 测试应用已从集群与 Git 清理（Traefik 与 eu DNS 保留备用，eu.tripbill.cn 现为死端 404）。

# 六、核心避坑与运维注意事项（学习环境专属）

1. **控制面单点风险**：京东云Server为唯一控制节点，宕机后无法新建/更新Pod，已有业务可正常运行，需依赖定时快照恢复。京东云出现过单次网络不可达（2026\-09\-08，约半小时），复发时优先检查京东云控制台实例状态与轻量防火墙。同日实例被重启（14:40）后 k3s 曾以 17s/次 crash\-loop 56 分钟（约200次）。iptables 规则仅存于内核内存，任何重启/清刷都会丢，hairpin DNAT 修复已改为**自愈守护**（`k3s-dnat-selfheal.service`，每15s断言规则存在且位于 KUBE\-SERVICES 链首，丢失即自动插回），经手动清刷与 k3s 重启双重演练验证；声明式下发入口 `ansible/playbooks/06-jdcloud-dnat-selfheal.yml`，节点重建后一条命令恢复。

2. **存储数据风险**：全量本地存储，Pod漂移、机器重建会丢失数据，禁止存储重要数据，仅用于学习测试。

3. **海外节点限制**：严禁系统组件、重业务调度至法兰克福，防止集群DNS解析超时、网络卡顿。

4. **资源管控红线**：绝不允许业务不配置resources限制，杜绝挤压控制面组件导致集群崩溃。

5. **网络波动容忍**：跨公网Wireguard隧道存在轻微抖动，属于正常现象，不影响学习使用。法兰克福节点因200ms+洲际延迟偶发NotReady抖动属正常，不影响业务运行。

6. **凭据安全红线**：禁止明文密码进入Git仓库，SSH一律密钥登录，`.env`/`ansible-vault`敏感信息隔离管理，已暴露密码及时轮换。

7. **监控选型红线**：禁用kube\-prometheus\-stack等重监控（1.5GB+内存），使用metrics\-server + kubectl top/k9s轻量方案。

# 七、CICD 演进路线（与 GitHub/Gitee 打通）

当前闭环：本地 push → 京东云 git daemon → ArgoCD → 三云节点。演进目标：提交代码到 GitHub/Gitee 即自动构建并部署到指定云节点。

1. **CI 构建**（P0 ✅）：业务仓 `duonera/TripJournal`（GitHub）+ Gitee 镜像仓 `jamesfeng_2009/TripJournal`，GitHub Actions 构建镜像推**阿里云 ACR 个人版实例**（免费公测，华东2上海，域名 `crpi-<id>.cn-shanghai.personal.cr.aliyuncs.com`，腾讯云节点同城拉取）。
2. **清单归一**（P1 ✅）：部署清单与代码同仓（`TripJournal/k8s/demo-app`），CI 构建后自动改同仓 `image:` tag 并双推（Gitee 为主源、GitHub 镜像同步）。
3. **ArgoCD 换源**（P1 ✅）：demo-app Application 源切至 Gitee（京东云节点拉 Gitee 稳），仓库凭证 `gitee-tripjournal`（kubectl 手工创建，不入 Git）；`argocd` 入口走 NodePort 30080，`demo-app` 走 NodePort 30081。
4. **Webhook 秒级触发**（P2 ✅）：Gitee push → `http://124.221.136.117:30082/gitee/<密钥>` → 协议适配器（argocd 命名空间 `webhook-adapter`，python:alpine，32Mi，NodePort 30082）→ 转 GitHub push 格式（HMAC 重签）→ argocd-server `/api/webhook` → Application 立即刷新。实测端到端约 20s（原轮询 180s）。清单见 `k8s/webhook-adapter.yaml`（手工 apply，系统组件不入 GitOps）。
5. **多集群纳管**（P3，就绪待触发）：当前单集群跨三云已达成"部署到任意云"目标，新建集群仅在需要爆炸半径隔离/合规/跨 region 时启动。就绪 Runbook：①新机器按六.1 规范装 k3s（WireGuard + `--node-external-ip`）；②控制面 `argocd cluster add <新集群ctx> --name <集群别名>` 生成集群凭证；③Application 的 `destination` 从 `server: https://kubernetes.default.svc` 改为 `name: <集群别名>`（业务 overlay 复用，去掉 nodeSelector 亲和改为 destination 区分）；④需要批量生成时把 helm values 里 `applicationSet.replicas` 从 0 改 1 启用 ApplicationSet（git generator 按集群枚举）。

> **完成记录（2026-09-08）**：P2 Webhook 秒级触发闭环——Gitee push 20s 内抵达 ArgoCD 刷新。**为什么需要适配器**：ArgoCD 原生 webhook 仅支持 GitHub/GitLab/Bitbucket/AzureDevOps/Gogs，不支持 Gitee；且 Gitee 开放 API 创建的 webhook 无法配置密码/签名（投递头 `X-Gitee-Token` 全空），故把密钥编入 URL 路径作能力令牌（`/gitee/<密钥>`），适配器校验路径后转成 GitHub 格式并 HMAC-SHA256 重签（`argocd-secret` 的 `webhook.github.secret`）。密钥存 `.env` 的 `argocd_webhook_secret`，同时在 `argocd-secret` 里以 `webhook.gitee.secret`/`webhook.github.secret` 双键注入。**踩坑备忘**：①`.env` 追加变量前文件末尾无换行符，变量拼进上一行导致空值连环坑（hook 密码为空、路径令牌为空）——追加环境变量文件前先确认末尾换行；②本机 curl 腾讯云节点自身 NodePort 会被 NAT hairpin 吞掉（与 ingress-nginx 探针同款问题），自测改走 Pod IP 或跨节点；③GitHub Actions 的 workflow_dispatch 需 PAT 具备 Actions RW，暂缺则用提交触发（paths 过滤）替代；④GitHub 镜像仓同步仍走法兰克福 git bundle 中继。

> **完成记录（2026-09-08）**：demo-app 全链路闭环验证通过——GitHub push → Actions 构建 → ACR 推镜像 → CI 改 tag 双推 → Gitee → ArgoCD 自动同步 → 腾讯云节点 Pod Running，`http://124.221.136.117:30081` 内外网均返回构建版本号。仓库分工：devops 仓 = 集群基础设施（ansible/terraform/helm + ArgoCD 引导），TripJournal 仓 = 应用代码 + 部署清单 + CI 流水线。凭证分布：本地 `devops/.env`（已 gitignore）；GitHub Actions Secrets ×5（ACR_USERNAME/ACR_PASSWORD/ACR_NAMESPACE/GITEE_USERNAME/GITEE_TOKEN，API 写入）；集群 `demo-app/acr-pull-secret` + `argocd/gitee-tripjournal`。踩坑备忘——①腾讯云 TCR 个人版控制台入口已并入企业版不再引导新用户，免费替代选阿里云 ACR 个人版（京东云 JCR 按存储计费无免费额度）；②ACR 个人版实例化域名 `crpi-` 前缀，新实例 DNS 全球传播有分钟级窗口（曾误写 `cri-` 叠加传播窗口，连续两次 CI 失败）；③GitHub 组织私有仓 Actions 默认禁用 + GITHUB_TOKEN 默认只读：需在组织/仓库 Settings→Actions 开启并选 "Read and write permissions"；④fine-grained PAT 权限清单：Contents RW + Workflows RW + Secrets RW + Actions R（workflow_dispatch 触发另需 Actions RW，暂缺则用提交触发代替）；⑤本地直连 github.com:443 被阻断：推送用 git bundle 经法兰克福节点中继（`git bundle → scp → clone --bare → push --mirror`），三云节点均可达 GitHub，法兰克福 TLS 最稳；⑥日常推 Gitee 本地直连无障碍，CI 双推在 Actions 海外节点执行无障碍。回滚：ArgoCD 界面 HISTORY 选中上一版本 SYNC 即回滚镜像。

# 八、方案最终总结

本方案基于现有三台差异化、跨地域、跨厂商服务器，规避了多云ETCD高可用缺陷、硬件负载不均、跨地域网络卡顿等所有问题，通过**角色分层、调度隔离、资源限流、最小权限网络**四大核心策略，搭建出一套稳定、规范、完全适配学习的完整DevOps链路。

整套架构可完美练习Terraform IaC、Ansible自动化、K3s集群运维、Helm包管理、Kustomize配置编排、ArgoCD GitOps全流程，同时实现三台机器独立部署不同业务、互不干扰、无跨云无效调用的核心诉求，是当前硬件条件下最优、最稳的落地方案。

# 九、生产级安全加固与容灾（2026-09-08）

目标：从"学习级"升级"生产级"。四项加固全部走 Git→ArgoCD 声明式闭环，业务 Pod 零重启完成。

1. **ArgoCD 管理界面启用 TLS（P1 ✅）**：helm values `server.insecure: false` + NodePort https 30443（自签证书 argocd-secret/argocd-server-tls），`https://124.221.136.117:30443` 登录，凭据不再明文传输；30080 HTTP 保留仅作 307 跳转。集群内 webhook 转发改走 `https://argocd-server.argocd.svc`（适配器 urllib 加 `ssl._create_unverified_context()` 跳过内部自签校验）。
2. **Sealed Secrets 接管集群凭证（P2 ✅）**：控制器 v0.39.1 部署于 kube-system（镜像走 docker.io 腾讯云加速源，nodeSelector 锁 tencent，manifest 见 `k8s/sealed-secrets/controller.yaml`）；`tripjournal-secrets`、`gitee-tripjournal`、`gitee-devops` 三个 Secret 已 seal 入 Git（overlays/cn + k8s/apps），明文源仅存 `secrets/`（gitignore）。kubeseal 0.39.1 darwin-arm64 经法兰克福中继安装本地 `~/bin/kubeseal`。踩坑——①控制器对"同名已存在且非其管理"的 Secret 报 `already exists and is not managed` 后会放弃重试，且注解 force-sync 因"update suppressed, no changes in spec"无效；处置：删除旧 Secret 与 SealedSecret CR 后从 Git 重新 apply，控制器立即重建（幂等，明文内容不变）。②本地直连 GitHub 下载二进制被阻断，复用"法兰克福中继"通道（curl→scp）。
3. **ArgoCD 源与控制面解耦（P2 ✅）**：Gitee 私有镜像仓 `jamesfeng_2009/devops`（API 自动创建）承载干净快照（剔除 .md/350MB terraform provider/hosts.ini，与 GitHub `jamesfeng2009/devops` 同内容）；`argocd-apps` 与 `tripjournal` Application 源切至 Gitee（凭证 SealedSecret 管理），控制面单点故障不再影响配置源；jdcloud git daemon（git://172.16.0.3）保留为备用连接。
4. **Webhook 链路扩展（P2 ✅）**：Gitee devops 仓 webhook（能力令牌路径方案）→ 适配器 30082 → ArgoCD，push 秒级触发两个平台 Application 同步。踩坑——①Gitee webhook URL 必须用 **http://**（适配器为纯 HTTP 服务，https 会在 TCP 层送进 TLS 握手字节，适配器报 Bad request version 400；TripJournal 钩子同为 http 方案）；②Gitee 的 `X-Gitee-Event` 实际值为 **"Push Hook"**（非 "push"），适配器按事件白名单匹配时被静默 200 丢弃——已改为小写化后包含匹配（`"push" in event.lower()`），并补 ignore 事件日志便于排查；③Gitee hook "test" 接口不发 push 事件头，不能用于端到端验证，需真实 push；④适配器滚动重启窗口会吞掉 hook 投递（Gitee 无自动重试），重启避开 push 高峰。
5. **异地容灾备份（P0/P1 ✅ 2026-09-09 闭环）**：
   - **隔离策略**：新建独立桶 **`devops-backup`**（Cloudflare API 创建，与爬虫桶 `novelcomics` 完全隔离），内部分 `pg/`（业务库）与 `k3s-state/`（集群状态）两个前缀，保留 30 天（脚本按文件名日期清理）。
   - **凭据方案**：复用 novelComics 项目的 R2 API Bearer Token（REST API 方案），**无需 S3 密钥与 rclone**——本地检索发现 novelComics 仅有 Bearer Token（`novelcomics/.env` 的 `R2_ACCOUNT_ID/R2_BEARER_TOKEN`）。凭据存放：集群 Secret `backup-r2`（sealed 入 Git）+ 京东云节点 `/root/.r2-backup-cred`（0600，ansible no_log 部署）。
   - **PG 备份（P0）**：CronJob `postgres-backup`（`overlays/cn/postgres-backup.yaml`）每日 05:00 北京时间 pg_dump -Fc → REST API PUT → 清理 30 天前对象，已实测全链路通过（dump 17.5K 落桶验证）。
   - **SQLite 快照（P1）**：`k3s-sqlite-backup.sh` 每 6h 本地保留 10 份 + 推 `k3s-state/`（失败不阻断本地备份，日志告警，下次重试），已实测通过（45M 快照落桶验证）。
   - 踩坑——①Cloudflare R2 生命周期规则 API（PUT /lifecycle）始终报 "Each rule must have a transition specified"，携带 TransitionObject 仍被拒，放弃平台级清理改脚本按文件名日期清理（文件名自带 YYYYMMDD）；②alpine busybox `date` 不支持 `-d '30 days ago'`，改 epoch 运算（GNU date 的剧本脚本不受影响）；③GitHub 对法兰克福节点的 git push 返回 403（API 同 token 正常，反滥用限制），GitHub 镜像只能本地直连推送（时通时断）。
   - 待办（可选）：该 Bearer Token权限较大（可建桶），后续可在 Cloudflare 为备份单独创建最小权限 API Token 替换。

# 十、可观测性与安全加固收官（2026-09-13，P0/P1/P2 全量落地）

## 10.1 多节点监控与告警（P0 ✅）

**Gatus 三节点互为外部探测**（`k8s/monitoring/gatus-{cp,cn,eu}.yaml`）：
- `gatus-cp`（京东云）：监控 ArgoCD/cert-manager/webhook-adapter 等控制面组件 + k8s-apiserver（token 探测 `[STATUS] == 401` 为健康）。
- `gatus-cn`（腾讯云）：探测国内业务端点（tripbill.cn、各 NodePort 业务）+ 金丝雀测试端点（验证告警链路）。
- `gatus-eu`（阿里云法兰克福）：从海外视角探测国内入口与控制面，跨地域互为备份探测。
- 告警通道：三份配置统一 `alerting.custom` POST 飞书 webhook（凭证 SealedSecret `monitoring-alerts`/`feishu-alerts` sealed 入 Git）。踩坑——①Gatus v5.x **没有 webhook 提供商**，必须用 `custom`（补 `method: POST` + `Content-Type: application/json` 头）；②证书过期检查占位符 `[CERTIFICATE_EXPIRATION_DAYS]` 已被移除，改用 `[CERTIFICATE_EXPIRATION] > 1200h`（50 天）；③条件不支持 `||` 逻辑或，多分支需拆成多条 condition。

**备份任务失败直发飞书（P0）**：
- PG（CronJob）：`postgres-backup` 脚本 `set -e` + `trap EXIT`，任一步骤失败（dump/上传/清理）立即 POST 飞书（`feishu-alerts` Secret 注入 `FEISHU_WEBHOOK_URL`）。
- SQLite（systemd）：`k3s-sqlite-backup.sh` 增加 `feishu()` + `STAGE` 阶段标记 + EXIT trap；R2 推送失败同样直发。凭据并入 `/root/.r2-backup-cred`（`FEISHU_WEBHOOK_URL` 行，ansible no_log 部署）。已实测：模拟失败触发（rc=1）+ webhook 直发验证（`StatusCode:0`）。

## 10.2 轻量日志栈 Loki + Promtail + Grafana（P2 ✅）

- `loki`（腾讯节点，文件系统存储，保留 7 天，内存严控）+ `promtail`（DaemonSet 三节点）+ `grafana`（NodePort 30085，Loki 数据源）。
- **关键踩坑——Promtail 全部 target 被静默丢弃（`targets_active_total=0`）**：kubernetes SD 发现的每个 target 必须带 `__host__` 标签且等于 Promtail 本机 hostname（官方文档：node affinity 校验），且 Pod 内 hostname 默认是 Pod 名而非节点名。修复两件套：①relabel 增加 `__meta_kubernetes_pod_node_name → __host__`；②容器注入 `env HOSTNAME`（downward API `spec.nodeName`）。修复后三节点 10/8/22 targets 全部采集，日志可查询（Loki label 含 namespace/pod/container/node）。

## 10.3 探针与容器加固（P1/P2 ✅）

**argocd-repo-server 探针调优（P1）**：`/healthz?full=true` 深度检查在低配节点易超 Helm 默认 `timeout=1s`，导致误判重启。helm values 放宽 liveness/readiness `timeoutSeconds: 5` + `periodSeconds: 20/10` + `failureThreshold: 5`，并新增 `startupProbe`（30×5s=150s 冷启动容忍）。升级命令（Helm v4 + 字段所有权冲突处置）：

```bash
# 本地下载 chart 超时走 gh-proxy 镜像
helm upgrade argocd /tmp/argo-cd-10.8.2.tgz -n argocd \
  -f helm/argocd-values.yaml --force-conflicts
# --force-conflicts 仅转移 argocd-secret 中 kubectl-patch 管理的 admin.passwordMtime 所有权，
# 不触碰 argocd-server 自管字段（webhook secret / tls）
```

**业务容器安全加固（P2，逐个验证落地）**：统一模式 `runAsNonRoot` + `readOnlyRootFilesystem` + `allowPrivilegeEscalation: false` + `drop ALL caps`，需写的路径用 emptyDir：

| 容器 | 运行身份 | 关键改动 | 备注 |
|---|---|---|---|
| trip-ledger-api | node(1000) | `/tmp` emptyDir | 监听 3000 非特权端口 |
| tripjournal-web | nginx(101) | listen 80→8080，`/var/cache/nginx`+`/run` emptyDir，conf 走 ConfigMap | Service targetPort 同步 8080（Ingress 仍 80） |
| postgres ×3 | postgres(70/999) | `/var/run/postgresql`+`/tmp` emptyDir | **前置：数据卷 chown**（见 runbook） |

未加固项（需镜像侧改造，Git 记录）：demo-app、intelligent-test 两个 ACR 私有镜像内置无普通用户且监听 80，需 Dockerfile 加 `USER` + 改非特权端口重新构建。

## 10.4 备份恢复演练与 Runbook（P1 ✅ 2026-09-13 实测通过）

**演练结论**：PG 恢复演练（R2 `pg/trip_ledger-20260912-1300.dump` → 临时库 restore_drill，11 张表行数与生产一致，ROW-COUNTS-MATCH）；SQLite 快照校验（本地 10 份 + R2 `k3s-state/state-20260913-133751.db` 45M 下载后 `PRAGMA integrity_check` ok，kine 2066 行可读）。

### Runbook A：PG 数据恢复（R2 最新工件）

```bash
# 1. 找最新工件（本地或任一节点均可执行）
source secrets/r2-backup-cred
curl -sf -H "Authorization: Bearer $R2_BEARER_TOKEN" \
  "https://api.cloudflare.com/client/v4/accounts/$R2_ACCOUNT_ID/r2/buckets/$R2_BUCKET/objects?prefix=pg/&per_page=100" \
  | jq -r '[.result[]?.key] | sort | last'

# 2. 集群内试灌/恢复（用参考 /tmp/pg-restore-drill.yaml 的 Job 模板改两处：
#    目标库为生产 trip_ledger 时跳过 row-count 对比、不 DROP；脚本走 CREATE DATABASE + pg_restore）
kubectl apply -f /tmp/pg-restore-drill.yaml && kubectl logs -f -n tripjournal job/pg-restore-drill

# 3. 验证后清理演练库
kubectl delete job pg-restore-drill -n tripjournal
```

### Runbook B：K3s SQLite 集群状态恢复

```bash
# 前提：新机部署好 k3s（同版本，看 10-k3s-server.yml）
# 1. 下载最新异地快照
source /root/.r2-backup-cred
LATEST=$(curl -sf -H "Authorization: Bearer $R2_BEARER_TOKEN" \
  "https://api.cloudflare.com/client/v4/accounts/$R2_ACCOUNT_ID/r2/buckets/$R2_BUCKET/objects?prefix=k3s-state/&per_page=100" \
  | jq -r '[.result[]?.key] | sort | last')
curl -sf -H "Authorization: Bearer $R2_BEARER_TOKEN" \
  "https://api.cloudflare.com/client/v4/accounts/$R2_ACCOUNT_ID/r2/buckets/$R2_BUCKET/objects/$LATEST" \
  -o /tmp/state.db

# 2. 校验
sqlite3 /tmp/state.db "PRAGMA integrity_check;"

# 3. 停 k3s → 覆盖 db → 重启（恢复到快照时刻的整个集群状态）
systemctl stop k3s
cp /tmp/state.db /var/lib/rancher/k3s/server/db/state.db
systemctl start k3s && kubectl get nodes
```

### Runbook C：PG 数据卷属主切换（容器加固前置操作）

```bash
# 顺序（以 tripjournal 为例，intelligent-test 同理 uid=999，StatefulSet 同样 scale 0）
# 1. 暂停 GitOps 自动同步（避免 selfHeal 拉回副本）
kubectl patch app tripjournal -n argocd --type=merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}'
kubectl scale deploy postgres -n tripjournal --replicas=0

# 2. 节点上 chown 数据目录（local-path 目录含 pvc-<uuid>_tripjournal_postgres-data）
ssh 腾讯云节点 'chown -R 70:70 /var/lib/rancher/k3s/storage/pvc-*_tripjournal_postgres-data'

# 3. push 后恢复自动同步（ArgoCD 以 uid 70 重建 Pod）
kubectl patch app tripjournal -n argocd --type=merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
kubectl wait -n tripjournal deploy/postgres --for=condition=available --timeout=180s
```

## 10.5 防火墙收窄方案（P0，三云控制台手动操作）

管理入口仅办公出口 IP `183.195.45.6` 与海外节点 `8.209.89.31`（Gatus 海外探测）可访问：

| 云 | 端口 | 现状 | 收窄目标（控制台安全组/防火墙规则） |
|---|---|---|---|
| 腾讯云 | 30443/tcp (ArgoCD UI) | 全网放行 | 删除 0.0.0.0/0 规则，改 `183.195.45.6/32` + `8.209.89.31/32` |
| 腾讯云 | 30085/tcp (Grafana) | 全网放行 | 同上两条 /32 |
| 腾讯云 | 30080/30081-30083 | 业务 NodePort | 保留（对外业务入口不动） |
| 京东云 | 30443/30085 不在本节点 | — | 无需操作（ArgoCD/Grafana 均在腾讯节点） |
| 阿里云 | 30083/tcp (intelligent-test) | 业务端口 | 保留 |

操作路径：腾讯云控制台 → 轻量应用服务器/CVM → 防火墙（或安全组）→ 找到 30443 与 30085 的允许规则 → 修改来源为上述两个 /32 IP → 保存。完成后验证：办公网 `https://124.221.136.117:30443` 可达、外网（如手机热点）应超时；Gatus-eu（阿里云 IP 源）对 30443 的探测持续正常。

## 10.6 新项目傻瓜式接入指引（reusable workflow，2026-09-13 落地）

流水线模板已抽为可复用 workflow：`duonera/intelligentTest/.github/workflows/build-deploy.yml`（同仓薄壳引用，规避私有仓跨 owner 不可见限制）。首次运行已验证全链路（构建→ACR→bump→双推→ArgoCD 双环境同步）。

**项目侧（一次性）：**

1. 从 intelligentTest 复制 `.github/workflows/ci.yml` 薄壳，改 4 个参数：

```yaml
jobs:
  build-and-deploy:
    uses: duonera/intelligentTest/.github/workflows/build-deploy.yml@main
    with:
      app_name: <镜像名，需与清单 image 后缀一致>
      dockerfile_dir: <Dockerfile 所在目录>
      manifest_path: k8s/base/deployment.yaml
      gitee_repo: <Gitee 镜像仓名>
    secrets: inherit
```

2. 复制 `k8s/` Kustomize 清单（base + overlays/<env>），改镜像名/端口/NodePort
3. GitHub Secrets 配置（与 intelligentTest 相同六个）：`ACR_NAMESPACE / ACR_USERNAME / ACR_PASSWORD / GITEE_USERNAME / GITEE_TOKEN`（模板按名引用）
4. Gitee API 创建私有镜像仓
5. 容器适配：非特权端口（>1024）、镜像内置普通用户或 manifest 指定 runAsUser、只读根挂 emptyDir、带 PG 先 chown 数据卷（Runbook C）

**平台侧（10 分钟）：**

1. 复制 `k8s/apps/intelligenttest-app.yaml` → 改 `repoURL` / `path` / `namespace`
2. `kubeseal` 密封新 Gitee 仓凭证 → `sealed-gitee-<name>.yaml`
3. `k8s/apps/kustomization.yaml` 加一行 → push devops 仓

**日常发布 = push main，零手工。** 流水线模板升级只需改 build-deploy.yml 一处，全部引用项目生效。

## 10.7 遗留待办

1. demo-app / intelligent-test 镜像侧改造（Dockerfile USER + 非特权端口）后补齐 runAsNonRoot。
2. intelligent-test 两个环境的 PG 数据卷 chown 999（Runbook C），配合该仓 `k8s/base/postgres.yaml` 加固提交一起生效。
3. 等 trip_ledger 有真实业务数据后，重跑恢复演练对比真实行数。
4. Prometheus 指标采集（Gatus/Loki 指标 → Grafana 面板）为可选增强。

> （注：部分内容可能由 AI 生成）
