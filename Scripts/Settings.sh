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

# ZN M2 大分区 rootfs 约 96MB。Docker/Samba/OAF/科学插件会让 factory.ubi 超过 120MB，
# U-Boot 写入不完整，开机无地址。先编能刷进去的体积，插件进系统后再用 U 盘装。
if [[ "$WRT_CONFIG" == "ZN-M2-WIFI-NO" ]]; then
	echo "ZN-M2: strip oversized packages so factory.ubi fits NAND"
	cat >> ./.config <<'EOF'
CONFIG_PACKAGE_docker=n
CONFIG_PACKAGE_dockerd=n
CONFIG_PACKAGE_docker-compose=n
CONFIG_PACKAGE_luci-app-dockerman=n
CONFIG_DOCKER_CGROUP_OPTIONS=n
CONFIG_DOCKER_NET_MACVLAN=n
CONFIG_DOCKER_STO_EXT4=n
CONFIG_PACKAGE_luci-app-samba4=n
CONFIG_PACKAGE_luci-app-oaf=n
CONFIG_PACKAGE_luci-app-homeproxy=n
CONFIG_PACKAGE_luci-app-gecoosac=n
CONFIG_PACKAGE_luci-app-ddns-go=n
CONFIG_PACKAGE_luci-app-partexp=n
CONFIG_PACKAGE_luci-app-mini-diskmanager=n
# 主题与体积适中的插件保留
CONFIG_PACKAGE_luci-app-store=y
CONFIG_PACKAGE_luci-app-zerotier=y
CONFIG_PACKAGE_luci-theme-argon=y
CONFIG_PACKAGE_luci-app-argon-config=y
EOF
fi

# 首次开机默认开启 UPnP，并把 WAN NAT 设为全锥形（需 kmod-nft-fullcone）
UCI_DEF_DIR="./package/base-files/files/etc/uci-defaults"
mkdir -p "$UCI_DEF_DIR"
cat > "$UCI_DEF_DIR/99-enable-upnp-fullcone" <<'EOF'
#!/bin/sh

# Full Cone NAT
uci -q set firewall.@defaults[0].fullcone='1'
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
echo "uci-defaults: enable UPnP + fullcone NAT"

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
done
