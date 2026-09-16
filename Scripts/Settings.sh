#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

#移除luci-app-attendedsysupgrade
sed -i "/attendedsysupgrade/d" $(find ./feeds/luci/collections/ -type f -name "Makefile")
#修改默认主题
sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" $(find ./feeds/luci/collections/ -type f -name "Makefile")
#修改immortalwrt.lan关联IP
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $(find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js")
#添加编译日期标识
sed -i "s/(\(luciversion || ''\))/(\1) + (' \/ $WRT_MARK-$WRT_DATE')/g" $(find ./feeds/luci/modules/luci-mod-status/ -type f -name "10_system.js")

WIFI_SH=$(find ./target/linux/{mediatek/filogic,qualcommax}/base-files/etc/uci-defaults/ -type f -name "*set-wireless.sh" 2>/dev/null)
WIFI_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
if [ -f "$WIFI_SH" ]; then
	#修改WIFI名称
	sed -i "s/BASE_SSID='.*'/BASE_SSID='$WRT_SSID'/g" $WIFI_SH
	#修改WIFI密码
	sed -i "s/BASE_WORD='.*'/BASE_WORD='$WRT_WORD'/g" $WIFI_SH
elif [ -f "$WIFI_UC" ]; then
	#修改WIFI名称
	sed -i "s/ssid='.*'/ssid='$WRT_SSID'/g" $WIFI_UC
	#修改WIFI密码
	sed -i "s/key='.*'/key='$WRT_WORD'/g" $WIFI_UC
fi

CFG_FILE="./package/base-files/files/bin/config_generate"
#修改默认IP地址
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $CFG_FILE
#修改默认主机名
sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" $CFG_FILE

#配置文件修改
echo "CONFIG_PACKAGE_luci=y" >> ./.config
echo "CONFIG_LUCI_LANG_zh_Hans=y" >> ./.config
echo "CONFIG_PACKAGE_luci-theme-$WRT_THEME=y" >> ./.config
echo "CONFIG_PACKAGE_luci-app-$WRT_THEME-config=y" >> ./.config

#引入私有扩展配置
if [ -f "$GITHUB_WORKSPACE/Config/PRIVATE.txt" ]; then
	echo "Applying private configurations from PRIVATE.txt..."
	cat $GITHUB_WORKSPACE/Config/PRIVATE.txt >> ./.config
fi

#手动调整的插件
if [ -n "$WRT_PACKAGE" ]; then
	echo -e "$WRT_PACKAGE" >> ./.config
fi

#无WIFI配置标志
if [[ "${WRT_CONFIG,,}" == *"wifi"* && "${WRT_CONFIG,,}" == *"no"* ]]; then
	echo "WRT_WIFI=wifi-no" >> $GITHUB_ENV
fi

#高通平台调整
DTS_PATH="./target/linux/qualcommax/dts/"
if [[ "${WRT_TARGET^^}" == *"QUALCOMMAX"* ]]; then
	#无WIFI配置调整Q6大小
	if [[ "${WRT_CONFIG,,}" == *"wifi"* && "${WRT_CONFIG,,}" == *"no"* ]]; then
		find $DTS_PATH -type f ! -iname '*nowifi*' -exec sed -i 's/ipq\(6018\|8074\).dtsi/ipq\1-nowifi.dtsi/g' {} +
		echo "qualcommax set up nowifi successfully!"
	fi
fi

# ZN M2 大分区 rootfs 约 96MB。Docker/Samba/科学插件仍不进 factory，刷后再用 U 盘装。
# OAF 的 kmod-oaf 必须编进内核，无法事后在线安装。
if [[ "$WRT_CONFIG" == "ZN-M2-WIFI-NO" ]]; then
	echo "ZN-M2: strip oversized packages so factory.ubi fits NAND; keep OAF kmod"
	cat >> ./.config <<'EOF'
CONFIG_PACKAGE_docker=n
CONFIG_PACKAGE_dockerd=n
CONFIG_PACKAGE_docker-compose=n
CONFIG_PACKAGE_luci-app-dockerman=n
CONFIG_DOCKER_CGROUP_OPTIONS=n
CONFIG_DOCKER_NET_MACVLAN=n
CONFIG_DOCKER_STO_EXT4=n
CONFIG_PACKAGE_luci-app-samba4=n
CONFIG_PACKAGE_luci-app-oaf=y
CONFIG_PACKAGE_kmod-oaf=y
CONFIG_PACKAGE_appfilter=y
CONFIG_PACKAGE_luci-app-homeproxy=n
CONFIG_PACKAGE_luci-app-gecoosac=n
CONFIG_PACKAGE_luci-app-ddns-go=n
CONFIG_PACKAGE_luci-app-partexp=n
CONFIG_PACKAGE_luci-app-mini-diskmanager=n
# 主题与体积适中的插件保留
CONFIG_PACKAGE_luci-app-store=y
CONFIG_PACKAGE_luci-app-ttyd=y
CONFIG_PACKAGE_luci-app-zerotier=y
CONFIG_PACKAGE_luci-theme-argon=y
CONFIG_PACKAGE_luci-app-argon-config=y
EOF
fi

# 统一 netfilter：系统防火墙只用 fw4/nftables。
# Docker/OAF 等仍可能执行 iptables 命令，必须走 iptables-nft，禁止 iptables-legacy，
# 否则会和 fw4 各写一套规则，NAT/TPROXY/UPnP 互相覆盖。
cat >> ./.config <<'EOF'
CONFIG_PACKAGE_firewall4=y
CONFIG_PACKAGE_firewall=n
CONFIG_PACKAGE_nftables-json=y
CONFIG_PACKAGE_kmod-nft-compat=y
CONFIG_PACKAGE_iptables-nft=y
CONFIG_PACKAGE_ip6tables-nft=y
CONFIG_PACKAGE_ebtables-nft=y
CONFIG_PACKAGE_iptables-legacy=n
CONFIG_PACKAGE_ip6tables-legacy=n
CONFIG_PACKAGE_xtables-legacy=n
CONFIG_PACKAGE_ebtables-legacy=n
CONFIG_PACKAGE_miniupnpd-nftables=y
CONFIG_PACKAGE_miniupnpd-iptables=n
CONFIG_PACKAGE_dnsmasq=n
CONFIG_PACKAGE_dnsmasq-full=y
CONFIG_PACKAGE_dnsmasq_full_nftset=y
EOF
echo "netfilter: fw4 + iptables-nft, legacy iptables disabled"

# 首次开机默认开启 UPnP，并把 WAN NAT 设为全锥形（需 kmod-nft-fullcone）
UCI_DEF_DIR="./package/base-files/files/etc/uci-defaults"
mkdir -p "$UCI_DEF_DIR"
cat > "$UCI_DEF_DIR/99-enable-upnp-fullcone" <<'EOF'
#!/bin/sh

# Full Cone NAT（nftables / kmod-nft-fullcone）
uci -q set firewall.@defaults[0].fullcone='1'
# nf flow offload 会绕过 TPROXY / OAF / Docker FORWARD，和混用规则一样表现为“规则加了不生效”
uci -q set firewall.@defaults[0].flow_offloading='0'
uci -q set firewall.@defaults[0].flow_offloading_hw='0'
i=0
while uci -q get firewall.@zone[$i] >/dev/null 2>&1; do
	name="$(uci -q get firewall.@zone[$i].name)"
	if [ "$name" = "wan" ]; then
		uci -q set firewall.@zone[$i].fullcone='1'
		uci -q set firewall.@zone[$i].fullcone4='1'
		uci -q set firewall.@zone[$i].fullcone6='1'
	fi
	i=$((i + 1))
done
uci -q commit firewall

# Passwall / Passwall2 默认走 nft，避免再写 iptables 表
for pkg in passwall passwall2; do
	if uci -q get ${pkg}.@global_forwarding[0] >/dev/null 2>&1; then
		uci -q set ${pkg}.@global_forwarding[0].use_nft='1'
		uci -q set ${pkg}.@global_forwarding[0].prefer_nft='1'
		uci -q commit "$pkg"
	fi
done

# UPnP / NAT-PMP
if uci -q get upnpd.config >/dev/null 2>&1; then
	uci -q set upnpd.config.enabled='1'
	uci -q set upnpd.config.enable_upnp='1'
	uci -q set upnpd.config.enable_natpmp='1'
	uci -q commit upnpd
fi

exit 0
EOF
chmod +x "$UCI_DEF_DIR/99-enable-upnp-fullcone"
echo "uci-defaults: enable UPnP + fullcone NAT, nft backend, no flow offload"

# 同步改掉源码包默认配置，避免仅靠 uci-defaults 时被覆盖
UPNP_CFG=$(find ./feeds ./package -type f -path '*/miniupnpd*/files/upnpd.config' -o -path '*/luci-app-upnp/*/upnpd' 2>/dev/null | head -n 1)
if [ -n "$UPNP_CFG" ] && [ -f "$UPNP_CFG" ]; then
	sed -i "s/option enabled '0'/option enabled '1'/g; s/option enable_upnp '0'/option enable_upnp '1'/g; s/option enable_natpmp '0'/option enable_natpmp '1'/g" "$UPNP_CFG"
	grep -q "option enabled" "$UPNP_CFG" || echo "	option enabled '1'" >> "$UPNP_CFG"
	echo "upnpd default config patched: $UPNP_CFG"
fi

FW_CFG=$(find ./package ./feeds -type f -path '*/firewall*/files/firewall.config' -o -path '*/firewall4/*/firewall' 2>/dev/null | head -n 5)
for f in $FW_CFG; do
	[ -f "$f" ] || continue
	if grep -q "option fullcone" "$f" 2>/dev/null; then
		sed -i "s/option fullcone '0'/option fullcone '1'/g" "$f"
	elif grep -q "config defaults" "$f"; then
		sed -i "/config defaults/,/^config /{s/option synflood_protect.*/&\n\toption fullcone '1'/}" "$f" 2>/dev/null || true
	fi
	sed -i "s/option flow_offloading '1'/option flow_offloading '0'/g; s/option flow_offloading_hw '1'/option flow_offloading_hw '0'/g" "$f"
done

# Passwall / Passwall2 源码默认改成 nft，避免首次启动先写 iptables 规则
find ./package ./feeds -type f \( \
	-path '*passwall*/0_default_config' -o \
	-path '*passwall2*/0_default_config' -o \
	-path '*/luci-app-passwall/root/etc/config/passwall' -o \
	-path '*/luci-app-passwall2/root/etc/config/passwall2' \
\) 2>/dev/null | while IFS= read -r f; do
	[ -f "$f" ] || continue
	sed -i "s/option use_nft '0'/option use_nft '1'/g; s/option prefer_nft '0'/option prefer_nft '1'/g" "$f"
	if grep -q "config global_forwarding" "$f" && ! grep -qE "prefer_nft|use_nft" "$f"; then
		sed -i "/config global_forwarding/a\\	option prefer_nft '1'" "$f"
	fi
	echo "passwall nft backend patched: $f"
done

# ZeroTier：Lean 界面（sample_config + 自动允许客户端 NAT）对接到官方 zerotier 的 global/network
ZT_SHARE="./package/base-files/files/usr/share/zerotier"
mkdir -p "$ZT_SHARE"
cat > "$ZT_SHARE/sync-uci.sh" <<'EOF'
#!/bin/sh
# Map luci-app-zerotier (sample_config/join/nat) to official zerotier package schema.

[ -f /etc/config/zerotier ] || touch /etc/config/zerotier
. /lib/functions.sh 2>/dev/null || exit 0

enabled=0
nat=0

sync_one() {
	local id="$1"
	[ -n "$id" ] || return 0
	local sec="zt_${id}"
	uci -q set "zerotier.${sec}=network"
	uci -q set "zerotier.${sec}.enabled=1"
	uci -q set "zerotier.${sec}.id=$id"
	uci -q set "zerotier.${sec}.allow_managed=1"
	uci -q set "zerotier.${sec}.allow_global=0"
	uci -q set "zerotier.${sec}.allow_default=0"
	uci -q set "zerotier.${sec}.allow_dns=0"
	if [ "$nat" = "1" ]; then
		uci -q set "zerotier.${sec}.fw_allow_input=1"
		uci -q set "zerotier.${sec}.fw_allow_forward=1"
		uci -q set "zerotier.${sec}.fw_allow_masq=1"
	fi
}

config_load zerotier
config_get_bool enabled sample_config enabled 0
config_get_bool nat sample_config nat 0

uci -q set zerotier.global=zerotier
uci -q set zerotier.global.enabled="$enabled"

for sec in $(uci -q show zerotier | sed -n "s/^zerotier\.\(zt_[0-9a-fA-F]*\)=network$/\1/p"); do
	uci -q delete "zerotier.$sec"
done

config_list_foreach sample_config join sync_one
uci -q commit zerotier
exit 0
EOF
chmod +x "$ZT_SHARE/sync-uci.sh"

cat > "$UCI_DEF_DIR/98-zerotier-local-nat" <<'EOF'
#!/bin/sh
uci -q set zerotier.sample_config=zerotier
uci -q set zerotier.sample_config.nat='1'
# 官方示例 earth 网络默认关掉，避免误加入
uci -q set zerotier.earth.enabled='0' 2>/dev/null || true
# 不预置任何网络 ID，由用户在 LuCI 里填写。过短的 secret 不是合法身份，丢掉以免节点地址乱跳
secret="$(uci -q get zerotier.global.secret || true)"
slen=$(printf %s "$secret" | wc -c)
if [ "$slen" -gt 0 ] && [ "$slen" -lt 80 ]; then
	uci -q delete zerotier.global.secret
fi
uci -q commit zerotier
[ -x /usr/share/zerotier/sync-uci.sh ] && /usr/share/zerotier/sync-uci.sh

# ZeroTier 从 zt* 访问路由器是 INPUT，默认 drop 会拦 LuCI/SSH。
# rfc1918_filter 会拦从 VPN 打开 192.168.x 管理页。
uci -q set uhttpd.main.rfc1918_filter='0'
uci -q commit uhttpd
if ! uci -q show firewall | grep -q "name='zerotier'"; then
	uci add firewall zone
	uci set firewall.@zone[-1].name='zerotier'
	uci set firewall.@zone[-1].input='ACCEPT'
	uci set firewall.@zone[-1].output='ACCEPT'
	uci set firewall.@zone[-1].forward='ACCEPT'
	uci add_list firewall.@zone[-1].device='zt+'
	uci add firewall forwarding
	uci set firewall.@forwarding[-1].src='zerotier'
	uci set firewall.@forwarding[-1].dest='lan'
	uci add firewall forwarding
	uci set firewall.@forwarding[-1].src='lan'
	uci set firewall.@forwarding[-1].dest='zerotier'
	uci add firewall forwarding
	uci set firewall.@forwarding[-1].src='zerotier'
	uci set firewall.@forwarding[-1].dest='wan'
	uci commit firewall
fi
exit 0
EOF
chmod +x "$UCI_DEF_DIR/98-zerotier-local-nat"

# 默认勾上「自动允许客户端 NAT」，保存后先同步官方 UCI 再启服务
find ./package ./feeds -type f -path '*luci-app-zerotier*/luasrc/model/cbi/zerotier/settings.lua' 2>/dev/null | while IFS= read -r f; do
	[ -f "$f" ] || continue
	sed -i '/Flag, "nat"/,/rmempty/{s/e.default = 0/e.default = 1/}' "$f"
	echo "zerotier Auto NAT default on: $f"
done

find ./package ./feeds -type f -path '*luci-app-zerotier*/root/etc/init.d/luci-zerotier' 2>/dev/null | while IFS= read -r f; do
	[ -f "$f" ] || continue
	if ! grep -q 'sync-uci.sh' "$f"; then
		sed -i '/^start() {/a\
	[ -x /usr/share/zerotier/sync-uci.sh ] \&\& /usr/share/zerotier/sync-uci.sh\
	[ -x /etc/init.d/zerotier ] \&\& /etc/init.d/zerotier running >/dev/null 2>\&1 || /etc/init.d/zerotier start >/dev/null 2>\&1 || true
' "$f"
	fi
	# 没加入网络时没有 zt 网卡，原脚本会无限 sleep，卡死开机和 LuCI
	if ! grep -q 'No zt device after' "$f"; then
		sed -i '/# Wait zt tun device/a\
	wait_n=0
' "$f"
		sed -i '/log "Waiting zt device/{n;a\
		wait_n=$((wait_n + 1))\
		[ "$wait_n" -gt 30 ] \&\& log "No zt device after 30s, skip NAT rules." \&\& return 0
' "$f"
	fi
	echo "zerotier luci init patched: $f"
done
echo "zerotier: Lean NAT luci + official daemon sync"
