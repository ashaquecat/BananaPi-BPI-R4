#!/bin/bash
#
# Modify default IP
sed -i 's/192.168.6.1/192.168.2.1/g' package/base-files/files/bin/config_generate

# Keep the initial root password empty, matching ImmortalWrt upstream.
# The root shadow entry should remain `root:::0:99999:7:::` so the user is
# forced to set a password manually after first login.
if [ -f package/base-files/files/etc/shadow ]; then
  sed -i -E 's#^root:[^:]*:#root::#' package/base-files/files/etc/shadow
fi

# Workaround: GCC 14 + musl fortify "always_inline memset: target specific option mismatch" in mbedtls
# Root cause: When building for aarch64_cortex-a53 with GCC 14, TARGET_CFLAGS includes
# target-specific CPU flags (e.g. -mcpu=cortex-a53+crypto) that conflict with the
# always_inline memset declared in musl's fortify/string.h. GCC 14 enforces strict
# target-option consistency for always_inline functions and raises an error.
# Fix: Disable _FORTIFY_SOURCE only for mbedtls so the fortify inline is not attempted,
# resolving the mismatch without affecting any other package's compilation.
if ! grep -q '_FORTIFY_SOURCE=0' package/libs/mbedtls/Makefile; then
  if grep -q 'TARGET_CFLAGS := \$(filter-out -O%' package/libs/mbedtls/Makefile; then
    sed -i '/TARGET_CFLAGS := \$(filter-out -O%/a TARGET_CFLAGS += -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0' package/libs/mbedtls/Makefile
  else
    echo 'TARGET_CFLAGS += -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0' >> package/libs/mbedtls/Makefile
  fi
fi

if command -v sudo >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
  sudo -E apt-get -qq update
  sudo -E apt-get -qq install -y llvm dwarves pahole
fi

patch_makefile_dep() {
  local file_path="$1"
  local old_text="$2"
  local new_text="$3"

  [ -f "$file_path" ] || return 0
  grep -qF "$old_text" "$file_path" || return 0

  PATCH_OLD_TEXT="$old_text" PATCH_NEW_TEXT="$new_text" \
    perl -0pi -e 'BEGIN { $old = $ENV{"PATCH_OLD_TEXT"}; $new = $ENV{"PATCH_NEW_TEXT"}; } s/\Q$old\E/$new/g' "$file_path"
}

prepare_requested_packages() {
  mkdir -p package/community
  (
    cd package/community

    [ -d luci-app-tailscale-community ] || \
      git clone --depth=1 https://github.com/Tokisaki-Galaxy/luci-app-tailscale-community
    [ -d bandix ] || \
      git clone --depth=1 https://github.com/timsaya/openwrt-bandix bandix
    [ -d luci-app-bandix ] || \
      git clone --depth=1 https://github.com/timsaya/luci-app-bandix
    if [ ! -d daed ] || [ ! -d luci-app-daed ]; then
      rm -rf dae daed luci-app-daed kiddin9-op-packages
      git clone --depth=1 --filter=blob:none --sparse https://github.com/kiddin9/op-packages kiddin9-op-packages
      (
        cd kiddin9-op-packages
        git sparse-checkout set daed luci-app-daed
      )
      [ -d kiddin9-op-packages/daed ] && mv kiddin9-op-packages/daed .
      [ -d kiddin9-op-packages/luci-app-daed ] && mv kiddin9-op-packages/luci-app-daed .
      rm -rf kiddin9-op-packages
    fi
    patch_makefile_dep \
      luci-app-daed/Makefile \
      '+daed +daed-geoip +daed-geosite' \
      '+daed +v2ray-geoip +v2ray-geosite'
    [ -d luci-app-lucky ] || \
      git clone --depth=1 https://github.com/gdy666/luci-app-lucky
    [ -d netspeedtest ] || \
      git clone --depth=1 https://github.com/sirpdboy/netspeedtest
    [ -d luci-app-partexp ] || \
      git clone --depth=1 https://github.com/sirpdboy/luci-app-partexp
    [ -d luci-app-wolplus ] || \
      git clone --depth=1 https://github.com/animegasan/luci-app-wolplus

    if [ ! -d luci-app-easytier ]; then
      rm -rf easytier-src
      git clone --depth=1 https://github.com/EasyTier/luci-app-easytier easytier-src
      [ -d easytier-src/easytier ] && mv easytier-src/easytier .
      [ -d easytier-src/luci-app-easytier ] && mv easytier-src/luci-app-easytier .
      rm -rf easytier-src
    fi

    if [ ! -d luci-app-ap-modem ]; then
      rm -rf kiddin9-openwrt-packages
      git clone --depth=1 --filter=blob:none --sparse https://github.com/QiuSimons/OpenWrt-Add kiddin9-openwrt-packages
      (
        cd kiddin9-openwrt-packages
        git sparse-checkout set luci-app-ap-modem
      )
      [ -d kiddin9-openwrt-packages/luci-app-ap-modem ] && mv kiddin9-openwrt-packages/luci-app-ap-modem .
      rm -rf kiddin9-openwrt-packages
    fi

    if [ ! -d luci-app-store ]; then
      rm -rf istore-ui-src istore-src
      git clone --depth=1 https://github.com/linkease/istore-ui istore-ui-src
      [ -d istore-ui-src/app-store-ui ] && mv istore-ui-src/app-store-ui .
      [ -d istore-ui-src/luci-app-store ] && mv istore-ui-src/luci-app-store .
      rm -rf istore-ui-src
      git clone --depth=1 https://github.com/linkease/istore istore-src
      [ -d istore-src/luci ] && cp -rf istore-src/luci/* .
      rm -rf istore-src
    fi
  )

  # The upstream diy-part3 may force wireless-tools through autocore. This image
  # is wired-only, so remove that dependency before make defconfig resolves deps.
  [ -f package/emortal/autocore/Makefile ] && \
    sed -i '/+TARGET_mediatek:wireless-tools/d' package/emortal/autocore/Makefile

  ./scripts/feeds install -a
}

prepare_requested_packages

# Persist local LuCI/menu defaults, VLAN defaults, and WAN management rules in
# the generated image.
if [ -f "$GITHUB_WORKSPACE/files/etc/uci-defaults/99-codex-bpi-r4-custom" ]; then
  mkdir -p files/etc/uci-defaults
  install -m 0755 "$GITHUB_WORKSPACE/files/etc/uci-defaults/99-codex-bpi-r4-custom" \
    files/etc/uci-defaults/99-codex-bpi-r4-custom
fi

# Enforce the final package profile after loading the seed config. This avoids
# stale entries in defconfig re-selecting services this image should omit.
set_config() {
  local sym="$1"
  local val="$2"

  [ -f .config ] || touch .config
  sed -i -E "/^(# )?CONFIG_${sym}(=| is not set)/d" .config
  if [ "$val" = "y" ]; then
    printf 'CONFIG_%s=y\n' "$sym" >> .config
  else
    printf '# CONFIG_%s is not set\n' "$sym" >> .config
  fi
}

drop_config_prefix() {
  local prefix="$1"

  [ -f .config ] || touch .config
  sed -i -E "/^CONFIG_${prefix}/d; /^# CONFIG_${prefix}[^ ]* is not set/d" .config
}

# Wired-only image: remove MTK vendor WiFi7 config and common wireless userland.
drop_config_prefix "MTK_WIFI7_"
drop_config_prefix "MTK_HWIFI_"
drop_config_prefix "first_card"
drop_config_prefix "second_card"
drop_config_prefix "DRIVER_11AC_SUPPORT"
drop_config_prefix "DRIVER_11AX_SUPPORT"
drop_config_prefix "DRIVER_11BE_SUPPORT"

for pkg in \
  kmod-cfg80211 kmod-mac80211 kmod-mt_hwifi kmod-mt7990 kmod-mt7991 \
  kmod-mt7996-firmware kmod-mt7996-233-firmware kmod-mt_wifi_cmn \
  kmod-mt_wifi7 mt7988-wo-firmware mtwifi-cfg mtwifi-wapp wifi-dats \
  wireless-regdb wireless-tools luci-app-mtwifi-cfg luci-app-wifischedule \
  iw iwinfo hostapd-common wpad-basic-mbedtls
do
  set_config "PACKAGE_${pkg}" n
done

# Remove cellular/WWAN packages and menu providers from the default image.
for opt in MODEMMANAGER_WITH_MBIM MODEMMANAGER_WITH_QMI MODEMMANAGER_WITH_QRTR; do
  set_config "$opt" n
done

for pkg in \
  luci-app-ap-modem luci-app-modemband modemband modemmanager sms-tool \
  luci-proto-3g luci-proto-mbim luci-proto-modemmanager luci-proto-qmi \
  luci-proto-quectel umbim uqmi quectel-cm fibocom-dial meig-cm \
  quectel-CM-5G comgt usbmode wwan \
  kmod-usb-net-cdc-mbim kmod-usb-net-qmi-wwan \
  kmod-usb-net-qmi-wwan-fibocom kmod-usb-net-qmi-wwan-quectel \
  kmod-usb-serial-option kmod-usb-serial-qualcomm kmod-usb-acm \
  kmod-usb-wdm kmod-wwan kmod-pcie_mhi kmod-mhi-bus \
  kmod-mhi-wwan-mbim kmod-qrtr kmod-qrtr-mhi kmod-mtk-t7xx
do
  set_config "PACKAGE_${pkg}" n
done

# Remove services explicitly not wanted in this build.
for pkg in \
  adguardhome ddns-scripts ddns-scripts-services ddnsto frpc nikki nlbwmon \
  shairport-sync shairport-sync-openssl smartdns socat wol \
  docker docker-compose dockerd containerd runc \
  luci-app-adguardhome luci-app-airplay2 luci-app-ddns luci-app-ddnsto \
  luci-app-dockerman luci-i18n-dockerman-zh-cn \
  luci-app-frpc luci-app-homeproxy luci-app-nikki luci-app-nlbwmon \
  luci-app-openclash luci-app-passwall luci-app-smartdns luci-app-socat \
  luci-app-ssr-plus luci-app-wol \
  softethervpn5-bridge softethervpn5-client softethervpn5-server \
  luci-app-softethervpn \
  shadowsocksr-libev-ssr-local shadowsocksr-libev-ssr-redir \
  shadowsocksr-libev-ssr-server geoview haproxy hysteria mihomo shadow-tls \
  shadowsocks-libev-config shadowsocks-libev-ss-local \
  shadowsocks-libev-ss-redir shadowsocks-libev-ss-server \
  shadowsocks-rust-sslocal shadowsocks-rust-ssserver simple-obfs-client \
  sing-box tcping tuic-client v2dat \
  v2ray-plugin xray-core xray-plugin
do
  set_config "PACKAGE_${pkg}" n
done

for opt in \
  PACKAGE_luci-app-passwall_Iptables_Transparent_Proxy \
  PACKAGE_luci-app-passwall_Nftables_Transparent_Proxy \
  PACKAGE_luci-app-passwall_INCLUDE_Geoview \
  PACKAGE_luci-app-passwall_INCLUDE_Haproxy \
  PACKAGE_luci-app-passwall_INCLUDE_Hysteria \
  PACKAGE_luci-app-passwall_INCLUDE_NaiveProxy \
  PACKAGE_luci-app-passwall_INCLUDE_Shadowsocks_Libev_Client \
  PACKAGE_luci-app-passwall_INCLUDE_Shadowsocks_Libev_Server \
  PACKAGE_luci-app-passwall_INCLUDE_Shadowsocks_Rust_Client \
  PACKAGE_luci-app-passwall_INCLUDE_Shadowsocks_Rust_Server \
  PACKAGE_luci-app-passwall_INCLUDE_ShadowsocksR_Libev_Client \
  PACKAGE_luci-app-passwall_INCLUDE_ShadowsocksR_Libev_Server \
  PACKAGE_luci-app-passwall_INCLUDE_Shadow_TLS \
  PACKAGE_luci-app-passwall_INCLUDE_Simple_Obfs \
  PACKAGE_luci-app-passwall_INCLUDE_SingBox \
  PACKAGE_luci-app-passwall_INCLUDE_V2ray_Geodata \
  PACKAGE_luci-app-passwall_INCLUDE_V2ray_Plugin \
  PACKAGE_luci-app-passwall_INCLUDE_Xray \
  PACKAGE_luci-app-passwall_INCLUDE_Xray_Plugin \
  PACKAGE_luci-app-ssr-plus_INCLUDE_Nftables_Transparent_Proxy \
  PACKAGE_luci-app-ssr-plus_INCLUDE_Xray \
  PACKAGE_luci-app-ssr-plus_INCLUDE_MosDNS \
  PACKAGE_luci-app-ssr-plus_INCLUDE_Mihomo \
  PACKAGE_luci-app-ssr-plus_INCLUDE_Shadowsocks_Rust_Client \
  PACKAGE_luci-app-ssr-plus_INCLUDE_Shadowsocks_Rust_Server \
  PACKAGE_luci-app-ssr-plus_INCLUDE_Shadowsocks_Simple_Obfs \
  PACKAGE_luci-app-ssr-plus_INCLUDE_ShadowsocksR_Libev_Client
do
  set_config "$opt" n
done

# Requested package profile: daed, LXC/container support, switch/VLAN support,
# and the retained LuCI/IPK tools from the router setup.
for pkg in \
  coremark kmod-nft-queue \
  bridge ip-bridge kmod-8021q kmod-bridge switch mii_mgr kmod-mediatek_hnat \
  luci-app-eqos-mtk luci-app-turboacc-mtk \
  kmod-sched-bpf kmod-xdp-sockets-diag libbpf bpftool libnetfilter-queue1 \
  daed luci-app-daed luci-i18n-daed-zh-cn \
  v2ray-geoip v2ray-geosite \
  lxc lxc-attach lxc-auto lxc-autostart lxc-cgroup lxc-checkconfig lxc-common \
  lxc-config lxc-configs lxc-console lxc-copy lxc-create lxc-destroy lxc-device \
  lxc-execute lxc-freeze lxc-hooks lxc-info lxc-ls lxc-monitor lxc-monitord \
  lxc-snapshot lxc-start lxc-stop lxc-templates lxc-top lxc-unfreeze \
  lxc-unshare lxc-wait liblxc rpcd-mod-lxc luci-app-lxc luci-i18n-lxc-zh-cn \
  kmod-veth kmod-macvlan kmod-dummy kmod-tun kmod-ikconfig \
  tailscale luci-app-tailscale-community luci-i18n-tailscale-community-zh-cn \
  bandix luci-app-bandix luci-i18n-bandix-zh-cn easytier luci-app-easytier \
  luci-app-lucky luci-app-netspeedtest luci-app-partexp luci-app-store \
  luci-app-wolplus luci-app-netdata luci-app-ttyd luci-app-vlmcsd \
  luci-app-diskman luci-app-mosdns luci-app-cpufreq \
  luci-proto-wireguard wireguard-tools rpcd-mod-wireguard
do
  set_config "PACKAGE_${pkg}" y
done

# Kernel options for daed eBPF/BTF and LXC/container namespaces.
for opt in \
  USE_LLVM_HOST HAS_BPF_TOOLCHAIN BPF_TOOLCHAIN_HOST \
  KERNEL_DEBUG_INFO KERNEL_DEBUG_INFO_BTF \
  KERNEL_NAMESPACES KERNEL_UTS_NS KERNEL_IPC_NS KERNEL_USER_NS \
  KERNEL_PID_NS KERNEL_NET_NS KERNEL_CGROUPS KERNEL_CGROUP_FREEZER \
  KERNEL_CGROUP_PIDS KERNEL_CGROUP_DEVICE KERNEL_CGROUP_CPUACCT \
  KERNEL_CGROUP_BPF KERNEL_SECCOMP KERNEL_KEYS
do
  set_config "$opt" y
done

for opt in BPF_TOOLCHAIN_BUILD_LLVM KERNEL_DEBUG_INFO_REDUCED DAED_USE_VMLINUX_BTF; do
  set_config "$opt" n
done

set_config "DAED_USE_KERNEL_BTF" y
