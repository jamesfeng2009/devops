#!/bin/sh
# 京东云 1:1 NAT hairpin 自愈守护（JD Cloud k3s Server 专属）
#
# 背景：kube-proxy 将 kubernetes Service (10.43.0.1:443) 的 endpoint DNAT 到公网 IP
#       (117.72.69.23:6443)，节点本机/Pod 的访问会经云 NAT hairpin 被厂商阻断导致超时。
#       必须在 nat OUTPUT/PREROUTING 的 KUBE-SERVICES 跳转【之前】插入直连私网 IP 的 DNAT
#       （首个匹配的 DNAT 生效，之后 nat 规则不再生效，因此顺序决定成败）。
#
# 为什么需要自愈：iptables 规则仅存在于内核内存。节点重启、k3s 重启/崩溃重建 KUBE 链、
#       任何外部清刷都会导致规则丢失或被挤到 KUBE-SERVICES 之后。oneshot 单元只在开机
#       跑一次，无法防御运行期丢失。本守护每 15s 断言一次：丢了就插回，顺序错就校正。
set -u

PRIVATE_TARGET="172.16.0.3:6443"
# ClusterIP: apiserver Service（Pod/节点本机 in-cluster 访问都走它）
RULE_CLUSTER="-p tcp -d 10.43.0.1/32 --dport 443 -j DNAT --to-destination ${PRIVATE_TARGET}"
# 公网 IP 直连：节点本机/外部服务访问 apiserver 公网地址
RULE_PUBLIC="-p tcp -d 117.72.69.23/32 --dport 6443 -j DNAT --to-destination ${PRIVATE_TARGET}"

# ensure_top <链名> <规则> <grep定位关键字>
# 保证规则存在且位于 KUBE-SERVICES 跳转之前；否则删除旧位置并重插到第 1 位
ensure_top() {
    chain="$1"; rule="$2"; key="$3"
    if iptables -t nat -C "$chain" $rule 2>/dev/null; then
        kube=$(iptables -t nat -S "$chain" 2>/dev/null | grep -n -- '-j KUBE-SERVICES' | head -1 | cut -d: -f1)
        # kube-proxy 规则尚未就绪（开机/重启中），等下一轮再校正，避免插入后被挤到后面
        [ -n "$kube" ] || return 0
        line=$(iptables -t nat -S "$chain" 2>/dev/null | grep -n -- "$key" | head -1 | cut -d: -f1)
        if [ -n "$line" ] && [ "$line" -lt "$kube" ]; then
            return 0
        fi
        # 存在但被 KUBE-SERVICES 遮蔽（或链被重建后位置异常）：删干净再插到第 1 位
        while iptables -t nat -C "$chain" $rule 2>/dev/null; do
            iptables -t nat -D "$chain" $rule
        done
    fi
    iptables -t nat -I "$chain" 1 $rule
    logger -t k3s-dnat-ensure "re-inserted DNAT at top of nat/$chain ($key)"
}

# ensure_any <链名> <规则>：仅断言存在（该目标不与任何 Service 匹配，位置无关）
ensure_any() {
    iptables -t nat -C "$1" $2 2>/dev/null || {
        iptables -t nat -A "$1" $2
        logger -t k3s-dnat-ensure "appended DNAT to nat/$1"
    }
}

while :; do
    ensure_top OUTPUT     "$RULE_CLUSTER" '-d 10.43.0.1/32'
    ensure_top OUTPUT     "$RULE_PUBLIC"  '-d 117.72.69.23/32'
    ensure_top PREROUTING "$RULE_CLUSTER" '-d 10.43.0.1/32'
    ensure_any  PREROUTING "$RULE_PUBLIC"
    sleep 15
done
