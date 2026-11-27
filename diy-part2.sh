#!/bin/bash
# ================================================================
# diy-part2.sh —— 默认值定制（在 .config 加载之后运行，cwd = ponwrt 根）
#   1) 时区 Asia/Shanghai (CST-8)
#   2) 5G WiFi：CN / auto / HE160
#   3) 概览页 CPU 行：USR/SYS + 每核明细
#   4) 固件版本追加作者与构建时间
# ================================================================

set -euo pipefail

echo "=========================================="
echo "默认值定制：时区 + 5G WiFi (diy-part2.sh)"
echo "=========================================="

# =============================================================
# 可配置：5G 无线参数
# 如需改动，直接改这里即可（编译期常量，会写进 uci-defaults 脚本）
# =============================================================
WIFI_5G_COUNTRY="${WIFI_5G_COUNTRY:-CN}"       # 国家代码（CN = 中国）
WIFI_5G_CHANNEL="${WIFI_5G_CHANNEL:-auto}"     # 信道（auto = 自动选择）
WIFI_5G_HTMODE="${WIFI_5G_HTMODE:-HE160}"      # 160MHz（WiFi6）；回落 HE80
WIFI_5G_FALLBACK="${WIFI_5G_FALLBACK:-HE80}"   # 硬件不支持 160MHz 时的回落值

# 可由 workflow 的 fw_author 输入项覆盖（经 env 注入）；本地单独跑时默认 qwe
FW_AUTHOR="${FW_AUTHOR:-qwe}"
FW_BUILD_TIME="${FW_BUILD_TIME:-}"
FW_DESC_SUFFIX="${FW_DESC_SUFFIX:-}"

echo "配置：5G country=$WIFI_5G_COUNTRY channel=$WIFI_5G_CHANNEL htmode=$WIFI_5G_HTMODE fallback=$WIFI_5G_FALLBACK"
echo "配置：FW_AUTHOR=$FW_AUTHOR"

# ---------------------------------------------------------
# 1. 修改 config_generate 的默认值（首次开机生成的 /etc/config/system）
# ---------------------------------------------------------
CFG="package/base-files/files/bin/config_generate"

if [ -f "$CFG" ]; then
  # 兼容 @system[-1]（旧）与 @system[0]（OpenWrt 21+）
  sed -i "s/option timezone.*/option timezone 'CST-8'/" "$CFG"
  sed -i "s/option zonename.*/option zonename 'Asia\/Shanghai'/" "$CFG"
  echo "✅ config_generate 默认时区 -> CST-8 / Asia/Shanghai"
else
  echo "::warning::未找到 $CFG，跳过默认值修改"
fi

# ---------------------------------------------------------
# 2. uci-defaults：即使保留了旧配置也强制刷成中国时区
# ---------------------------------------------------------
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/99-timezone-cn <<'EOF'
#!/bin/sh
uci -q batch <<'UCI'
set system.@system[0].zonename='Asia/Shanghai'
set system.@system[0].timezone='CST-8'
commit system
UCI
exit 0
EOF
chmod +x files/etc/uci-defaults/99-timezone-cn
echo "✅ uci-defaults 时区脚本已写入"

# ---------------------------------------------------------
# 3. 补上亚洲时区数据库包（LuCI 显示与时区切换需要）
# ---------------------------------------------------------
if [ -f .config ]; then
  sed -i '/^CONFIG_PACKAGE_zoneinfo-asia=/d; /^# CONFIG_PACKAGE_zoneinfo-asia is not set/d' .config
  echo "CONFIG_PACKAGE_zoneinfo-asia=y    # 亚洲时区数据库（中国时区需要）" >> .config
  echo "✅ zoneinfo-asia 已加入 .config"

  # libffi：见 diy-part1.sh 的同名段落。源码树原本没有这个包，
  # python3(3.14) 的 _ctypes 却必须要它的 ffi.h / libffi.pc，
  # 缺了就 fatal error 拖垮 world。这里显式打开 target 版，
  # 让 Build/InstallDev 把头文件装进 staging_dir。
  sed -i '/^CONFIG_PACKAGE_libffi=/d; /^# CONFIG_PACKAGE_libffi is not set/d' .config
  echo "CONFIG_PACKAGE_libffi=y           # python3 _ctypes 需要 ffi.h / libffi.pc" >> .config
  echo "✅ libffi 已加入 .config"
fi

# ---------------------------------------------------------
# 4. 5G WiFi：CN / auto / HE160
#   分两层：编译期改 detect 脚本默认值（best effort，各版本路径不同）；
#   运行期用 uci-defaults 首启强制刷（主要手段，保留配置升级也生效，且自带
#   「wireless 尚未生成就先 wifi config」的逻辑）。
# ---------------------------------------------------------

# ---- 4a. 编译期：改 detect 脚本默认值（best effort） ----
DETECT_SCRIPT=""
for cand in \
  "package/kernel/mac80211/files/lib/wifi/mac80211.sh" \
  "package/kernel/mac80211/files/lib/wifi/mac80211.uc" \
  "package/network/services/hostapd/files/lib/wifi/mac80211.sh"; do
  [ -f "$cand" ] && { DETECT_SCRIPT="$cand"; break; }
done

if [ -n "$DETECT_SCRIPT" ]; then
  # 5G（11a / band 5g）的默认信道改成 auto
  sed -i "s/option channel '36'/option channel 'auto'/g" "$DETECT_SCRIPT"
  sed -i "s/option channel='36'/option channel='auto'/g" "$DETECT_SCRIPT"
  echo "✅ detect 脚本默认信道 -> auto ($DETECT_SCRIPT)"
else
  echo "::warning::未找到无线 detect 脚本，跳过编译期默认值修改（由 uci-defaults 兜底）"
fi

# ---- 4b. 运行期：uci-defaults 首启强制刷 ----
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/96-wifi-5g-cn <<UCEOF
#!/bin/sh
# 5G WiFi 默认值：国家码 CN、信道 auto、频宽 160MHz
# 由 diy-part2.sh 生成（编译期常量注入）

COUNTRY='$WIFI_5G_COUNTRY'
CHANNEL='$WIFI_5G_CHANNEL'
HTMODE='$WIFI_5G_HTMODE'
FALLBACK='$WIFI_5G_FALLBACK'

log() { logger -t wifi-5g "\$@"; }

# uci-defaults 可能在 wifi config 之前执行 —— 没生成就先生成
if [ ! -f /etc/config/wireless ]; then
	command -v wifi >/dev/null 2>&1 && wifi config >/dev/null 2>&1
fi
[ -f /etc/config/wireless ] || { log "未找到 /etc/config/wireless，跳过"; exit 0; }

# 检测该 phy 是否支持 160MHz（兼容 "160 MHz" 与 "80+80 MHz" 两种表述）
support_160() {
	local phy="\$1"
	[ -z "\$phy" ] && return 1
	command -v iw >/dev/null 2>&1 || return 1
	iw phy "\$phy" info 2>/dev/null | grep -qE '160 MHz|80\+80 MHz' || return 1
	return 0
}

changed=0
for dev in \$(uci -q show wireless | sed -n 's/^wireless\.\([A-Za-z0-9_-]*\)=wifi-device\$/\1/p'); do
	band="\$(uci -q get wireless.\$dev.band 2>/dev/null)"
	hwmode="\$(uci -q get wireless.\$dev.hwmode 2>/dev/null)"

	# 只处理 5G：新版用 band='5g'，旧版用 hwmode='11a'
	is5g=0
	[ "\$band" = "5g" ] && is5g=1
	[ -z "\$band" ] && [ "\$hwmode" = "11a" ] && is5g=1
	[ "\$is5g" = "0" ] && continue

	# 频宽：确认不支持 160MHz 才回落
	# 取不到 phy 名时不检测（保持 HTMODE）—— 避免无 phy 选项的 radio 被误判回落
	ht="\$HTMODE"
	phy="\$(uci -q get wireless.\$dev.phy 2>/dev/null)"
	if [ -n "\$phy" ] && ! support_160 "\$phy"; then
		ht="\$FALLBACK"
		log "\$dev：未检测到 160MHz 能力，回落为 \$ht"
	fi

	uci -q set wireless.\$dev.country="\$COUNTRY"
	uci -q set wireless.\$dev.country_ie='1'
	uci -q set wireless.\$dev.channel="\$CHANNEL"
	uci -q set wireless.\$dev.htmode="\$ht"

	log "\$dev：country=\$COUNTRY channel=\$CHANNEL htmode=\$ht"
	changed=1
done

if [ "\$changed" = "1" ]; then
	uci -q commit wireless
	# 重载而非重启：避免首启期间无线中断后不可恢复
	command -v wifi >/dev/null 2>&1 && wifi reload >/dev/null 2>&1 || true
	log "已提交 wireless 配置"
else
	log "未找到 5G radio，未做任何修改"
fi

exit 0
UCEOF
chmod +x files/etc/uci-defaults/96-wifi-5g-cn
echo "✅ uci-defaults 5G WiFi 脚本已写入（country=$WIFI_5G_COUNTRY channel=$WIFI_5G_CHANNEL htmode=$WIFI_5G_HTMODE）"

# ---- 4c. 确保 hostapd 支持 160MHz / 11ax ----
# wpad-openssl = 完整版 hostapd，支持 HE160；
# 若用的是 wpad-basic / hostapd-basic（精简版），160MHz 可能不生效。
if [ -f .config ]; then
  if grep -qE "^CONFIG_PACKAGE_(wpad-basic|hostapd-basic)=y" .config; then
    echo "::warning::检测到精简版 wpad/hostapd-basic，160MHz 可能不支持"
  fi
  # 无线工具：uci-defaults 里的能力检测需要 iw
  if ! grep -q "^CONFIG_PACKAGE_iw=y" .config; then
    sed -i '/^CONFIG_PACKAGE_iw=/d; /^# CONFIG_PACKAGE_iw is not set/d' .config
    echo "CONFIG_PACKAGE_iw=y                       # 无线命令行工具（160MHz 能力检测需要）" >> .config
    echo "✅ iw 已加入 .config"
  fi
fi

# ---------------------------------------------------------
# 5. 概览页「CPU 使用率（%）」行：USR/SYS + 每核明细
#   luci 原本是 popen("top -n1 | awk ...") 的单值。这里只把它改指到
#   files/sbin/cpuusage，前端 10_system.js 与 ACL 都不动。
#   纯显示层：找不到目标只 warning，不让它把几小时的构建搞挂。
# ---------------------------------------------------------
PATCH_CPUUSAGE="$(dirname "$0")/scripts/patch-luci-cpuusage.sh"
if [ -f "$PATCH_CPUUSAGE" ]; then
  PONWRT_DIR=. bash "$PATCH_CPUUSAGE" || true
else
  echo "::warning::未找到 $PATCH_CPUUSAGE，跳过概览页 CPU 使用率行定制"
fi

[ -z "$FW_BUILD_TIME" ] && FW_BUILD_TIME="$(TZ="${TZ:-Asia/Shanghai}" date '+%Y-%m-%d %H:%M')"

VER_CODE="$(sed -n 's/^CONFIG_VERSION_CODE="\(.*\)"$/\1/p' .config 2>/dev/null || true)"
if [ -n "$VER_CODE" ]; then
  DESC_BODY='%D %V %C'
else
  DESC_BODY='%D %V'
fi
[ -z "$FW_DESC_SUFFIX" ] && FW_DESC_SUFFIX="· ${FW_AUTHOR} · ${FW_BUILD_TIME}"

RELEASE_TPL="package/base-files/files/etc/openwrt_release"
OSREL_TPL="package/base-files/files/usr/lib/os-release"

# 用 perl + 环境变量传替换文本：作者名/后缀里带 / | # & 都不会搞坏语法
# （直接 sed "s|...|${FW_DESC_SUFFIX}|" 遇到这些字符会炸）
FW_DESC_LINE="DISTRIB_DESCRIPTION='${DESC_BODY} ${FW_DESC_SUFFIX}'"
OSREL_LINE="OPENWRT_RELEASE=\"${DESC_BODY} ${FW_DESC_SUFFIX}\""
export FW_DESC_LINE OSREL_LINE

if [ -f "$RELEASE_TPL" ]; then
  # 只替换 DISTRIB_DESCRIPTION 行，不动 DISTRIB_ID / DISTRIB_RELEASE 等其它行
  perl -i -pe 's/^DISTRIB_DESCRIPTION=.*/$ENV{FW_DESC_LINE}/' "$RELEASE_TPL"
  echo "✅ 固件版本模板 -> $FW_DESC_LINE"
else
  echo "::warning::未找到 $RELEASE_TPL，固件版本不会带构建信息"
fi

# os-release 同步（部分工具/LuCI 版本读它；%B 只是 SOURCE_DATE_EPOCH 时间戳，不好看）
if [ -f "$OSREL_TPL" ]; then
  perl -i -pe 's/^OPENWRT_RELEASE=.*/$ENV{OSREL_LINE}/' "$OSREL_TPL"
  echo "✅ os-release 同步 -> $OSREL_LINE"
fi

# 用 -f 不要用 -x：git checkout / Windows 打包会丢可执行位，-x 判失败会静默整段跳过。
# 末尾 || true：本文件开头是 set -euo pipefail，被 source 的子脚本里任何一步
# 返回非 0 都会让这里当场退出，后面的步骤全不执行且整轮构建中断。
# 加密是可选增强，不该有能力搞挂构建。
[ -f scripts/diy-part2-crypto.sh ] && . ./scripts/diy-part2-crypto.sh || true

echo "🎉 diy-part2.sh 执行完毕 (author=$FW_AUTHOR)"

# =========================================================
# 9. WiFi→PON 硬件转发（WED/NPU）—— HM2004-DU 实验性开启
#    依据原厂 QWRT 固件逆向（见 reverse-out/逆向报告.md）：
#      · 原厂用 MT7916 专用 NPU 固件 en7581_MT7916_npu_*.bin
#      · 需要 npu-pkt(22MB) + npu-ba(2MB) 额外内存区
#      · airoha,mt7916-rx-only-memory 标记 RX-only 卸载
#    上游驱动已支持从 DTS 读 firmware-name 与 pkt/ba 区，无需改驱动。
#    开关：ADD_NPU_OFFLOAD=true 才注入，默认关闭（实验阶段）
# =========================================================
if [ "${ADD_NPU_OFFLOAD:-false}" = "true" ]; then
  DTS="target/linux/airoha/dts/an7581-h3c-hm2004-du.dts"
  DTSI_NAME="an7581-h3c-hm2004-du-npu.dtsi"
  DTSI_SRC="$GITHUB_WORKSPACE/npu-local-hold/$DTSI_NAME"

  if [ ! -f "$DTS" ]; then
    echo "::warning::未找到 $DTS，跳过 NPU 注入"
  elif [ ! -f "$DTSI_SRC" ]; then
    echo "::warning::未找到叠加层 $DTSI_SRC，跳过 NPU 注入"
  elif grep -q "$DTSI_NAME" "$DTS"; then
    echo "ℹ NPU 叠加层已存在，跳过"
  else
    # 在 an7581.dtsi 的 include 之后插入叠加层 include
    perl -i -pe "s|(#include \"an7581\.dtsi\")|\$1\n#include \"$DTSI_NAME\"| unless \$done; \$done=1 if /#include \"an7581\\.dtsi\"/" "$DTS"
    cp "$DTSI_SRC" "target/linux/airoha/dts/$DTSI_NAME"
    mkdir -p files/lib/firmware/airoha
    cp "$GITHUB_WORKSPACE/npu-local-hold/lib/firmware/airoha/en7581_MT7916_npu_"*.bin files/lib/firmware/airoha/
    echo "✅ NPU/WED 叠加层已注入：$DTSI_NAME（含固件）"
    grep -n "an7581.*dtsi" "$DTS" | head -3
  fi

  # NPU 固件文件：files/ 下已放好，OpenWrt 会自动打包进 rootfs
  if [ -f "$GITHUB_WORKSPACE/npu-local-hold/lib/firmware/airoha/en7581_MT7916_npu_rv32.bin" ]; then
    echo "✅ MT7916 NPU 固件已在 files/ 中，将随固件打包"
  else
    echo "::warning::未找到 MT7916 NPU 固件（npu-local-hold/lib/firmware/airoha/）"
  fi

  # ---------------------------------------------------------
  # 内核 Kconfig 符号必须写进「目标 config」，不能只写 .config
  #
  # target/linux/airoha/an7581/config-6.18 是内核配置的基座；追加到
  # TOPDIR/.config 的 CONFIG_NET_* 会在 kernel_oldconfig 阶段被基座覆盖。
  #
  # 本套实现（wed-cpu-ppe）只依赖两个符号，且都不在 NET_VENDOR_MEDIATEK
  # 菜单下，因此不需要打开 MediaTek 厂商菜单（那会把整张菜单变可见，
  # 未回答的符号变成 kconfig 的 (NEW) 交互提示，syncconfig 无 stdin 直接
  # 报错——之前为此连挂两次构建）：
  #   NET_AIROHA_SOC_WED        bool，990-02 在 airoha/Kconfig 里定义，
  #                             select NET_MEDIATEK_WED_COMMON
  #   NET_MEDIATEK_WED_COMMON   990-01 在 drivers/net/ethernet/Kconfig 顶层
  #                             定义，负责编 mtk_wed_ops.o 并让
  #                             struct mtk_wed_device 有内容
  # ---------------------------------------------------------
  KCONFIG="target/linux/airoha/an7581/config-6.18"
  if [ -f "$KCONFIG" ]; then
    for sym in CONFIG_NET_AIROHA_SOC_WED CONFIG_NET_MEDIATEK_WED_COMMON; do
      sed -i "s/^# ${sym} is not set$/${sym}=y/" "$KCONFIG"
      sed -i "s/^${sym}=[ym]$/${sym}=y/" "$KCONFIG"
      grep -qxF "${sym}=y" "$KCONFIG" || echo "${sym}=y" >> "$KCONFIG"
    done
    # 旧方案残留：这三项是我方 952 的写法，本套不再需要，且会重新激活
    # MediaTek 厂商菜单（连带 (NEW) 提示），一并清掉。
    for sym in CONFIG_NET_MEDIATEK_SOC_WED CONFIG_NET_VENDOR_MEDIATEK \
               CONFIG_NET_MEDIATEK_SOC CONFIG_NET_MEDIATEK_STAR_EMAC; do
      sed -i "s/^${sym}=[ym]$/# ${sym} is not set/" "$KCONFIG"
    done
    echo "✅ 内核目标配置（WED）："
    grep -nE "NET_AIROHA_SOC_WED|NET_MEDIATEK_WED_COMMON|NET_AIROHA_NPU|NET_VENDOR_MEDIATEK|NET_MEDIATEK_SOC" "$KCONFIG"
  else
    echo "::warning::未找到内核目标配置 $KCONFIG（WED 符号将不生效）"
  fi

  # ---------------------------------------------------------
  # 内核补丁：AN7581 WED v1 TX + PPE（供应商 wed-cpu-ppe 方案）
  #
  # 来源：参考实现 wed-cpu-ppe.diff（同 ponwrt 基座、同 Linux 6.18）。
  # 本机 6.18.60 上前置 931/932/941-02/947/951 之后，按下列顺序应用：
  #   400      airoha_npu.c：tx-bufid / tx-pkt 内存区改为「DTS 有才下发」，
  #            MT7916 这类 RX-only 设计不必为其分配内存，也不会 probe 失败
  #   990-01   新增 NET_MEDIATEK_WED_COMMON（ethernet 顶层，无厂商依赖），
  #            mtk_wed_ops.o 挪到 drivers/net/ethernet/，增加带互斥的
  #            mtk_wed_ops_register/unregister，抽出 mtk_wed_private.h
  #            （其中 mtk_wed_hw 增加 struct airoha_eth *airoha）
  #   990-02   新增 NET_AIROHA_SOC_WED + airoha_wed.c/h/_debugfs.c：
  #            AN7581 WED v1 TX 后端（PPE→PSE port3→WDMA→WED）
  #   991      AN7581 的 PPE 改由 CPU 直接初始化（hw_initialized 本地置位），
  #            PPE 不再依赖 NPU 完成 offload_setup
  #
  # 与旧方案（952/953/954，来自 wuziwei 的 HG5585F 分支）的关系：
  # 二者不能共存——952 与 990-01 抢同一个 mediatek/Kconfig，且 952 需要把
  # NET_MEDIATEK_SOC_WED 塞给 ARCH_AIROHA，会连带激活整张 MediaTek 厂商
  # 菜单产生 kconfig (NEW) 交互提示（syncconfig 无 stdin，直接构建失败，
  # 我们为此连挂两次）。本套用独立符号，彻底绕开。
  #
  # 方向差异：本套覆盖 下行（PON→WiFi）WED TX 卸载 + PPE 硬件转发；
  # 上行（WiFi→PON）的 RX 仍走 PCIe 到 CPU。旧 954 是上行 NPU RX，但
  # 多轮实测始终不产帧，故放弃。
  # NPU_LEGACY_ABI 开关保留但不再影响注入（legacy ABI 路线已证伪）。
  # ---------------------------------------------------------
  KVER="$(sed -n 's/^KERNEL_PATCHVER:=//p' target/linux/airoha/Makefile 2>/dev/null || echo 6.18)"
  KPATCH_DIR="target/linux/airoha/patches-${KVER}"
  if [ -d "$KPATCH_DIR" ]; then
    for pn in 400-net-airoha-npu-support-wlan-rx-only-offload \
              990-01-net-ethernet-share-mtk-wed-ops-and-private-header \
              990-02-net-airoha-add-AN7581-WED-support \
              991-net-airoha-ppe-direct-cpu-programming-for-AN7581; do
      src=""
      [ -f "$GITHUB_WORKSPACE/patches/airoha/$pn.patch" ] && \
        src="$GITHUB_WORKSPACE/patches/airoha/$pn.patch"
      [ -z "$src" ] && [ -f "$GITHUB_WORKSPACE/patches/airoha/ppe-fixes/$pn.patch" ] && \
        src="$GITHUB_WORKSPACE/patches/airoha/ppe-fixes/$pn.patch"
      if [ -n "$src" ]; then
        cp "$src" "$KPATCH_DIR/$pn.patch"
        echo "✅ 内核补丁已注入：$pn"
      else
        echo "::warning::内核补丁缺失：$pn.patch"
      fi
    done
    echo "ℹ NPU_LEGACY_ABI=${NPU_LEGACY_ABI:-false}（legacy 路线已证伪，忽略）"
  else
    echo "::warning::未找到内核补丁目录 $KPATCH_DIR"
  fi

  # ---------------------------------------------------------
  # mt76 补丁：启用 Airoha WED（来源同 wed-cpu-ppe.diff）
  #   120     dma/connac/wed 各处把内核判断从「仅 NET_MEDIATEK_SOC_WED」
  #           扩成「MEDIATEK 或 AIROHA」，并给 MT7615 加 WED TX 卸载
  #   121     MT7916 的 CTXD 与 TX 流控（WED 下必须，否则发送卡住）
  #   122     mt7915 的 wed_enable 默认值改为 IS_ENABLED(NET_AIROHA_SOC_WED)
  # 三者已在 openwrt/mt76@0936617d（本机构建实际使用的版本）上验证零 fuzz。
  # 取代此前的 402/405 与 HG5585F 的 120/121。
  # ---------------------------------------------------------
  MT76_DIR="package/kernel/mt76"
  if [ -d "$MT76_DIR" ]; then
    mkdir -p "$MT76_DIR/patches"
    for pn in 120-wifi-mt76-enable-Airoha-WED-and-add-MT7615-transmit-offload \
              121-mt7915-enable-CTXD-and-TX-flow-control-for-WED-on-MT7916 \
              122-mt7915-default-enable-wed-for-airoha; do
      src="$GITHUB_WORKSPACE/patches/airoha/mt76/$pn.patch"
      if [ -f "$src" ]; then
        cp "$src" "$MT76_DIR/patches/$pn.patch"
        echo "✅ mt76 补丁已注入：$pn"
      else
        echo "::warning::mt76 补丁缺失：$pn"
      fi
    done
    # 包 Makefile：an7581 上把 wed_enable 设为 Y
    #
    # 122 已把 mt7915 的 wed_enable 默认值改成 IS_ENABLED(CONFIG_NET_AIROHA_SOC_WED)，
    # 这里再补 MODPARAMS 与之对应，保证 insmod 时即开启（与参考实现一致）。
    #
    # 注意：不要启用 CONFIG_MT76_NPU / CONFIG_MT7915_NPU。那条是旧的 NPU RX
    # 方案，mt76 根目录 npu.c 会调用 airoha_npu_wlan_* 系列函数，而内核只
    # EXPORT_SYMBOL_GPL 了 airoha_npu_get/put，其余未导出，模块链接必然失败。
    if ! grep -q "CONFIG_TARGET_airoha_an7581" "$MT76_DIR/Makefile"; then
      sed -i 's|^ifneq ($(CONFIG_TARGET_mediatek_filogic)$(CONFIG_TARGET_mediatek_mt7622),)$|ifneq ($(CONFIG_TARGET_mediatek_filogic)$(CONFIG_TARGET_mediatek_mt7622)$(CONFIG_TARGET_airoha_an7581),)|' "$MT76_DIR/Makefile"
    fi
    grep -n "MODPARAMS.mt7915e" "$MT76_DIR/Makefile" | head -2
    echo "✅ mt76 WED 补丁已注入（含 wed_enable=Y 的 MODPARAMS）"
    grep -A6 "kmod-mt7915e" "$MT76_DIR/Makefile" | head -8
  else
    echo "::warning::mt76 WED 补丁未注入（$MT76_DIR 或补丁缺失）"
  fi
else
  echo "ℹ ADD_NPU_OFFLOAD != true，保持默认（无 WiFi 硬件转发）"
fi

# ---------------------------------------------------------
# A 方案脚本执行位兜底：git checkout 可能丢 exec bit，
# workflow 只 chmod 了 files/sbin 与 uci-defaults，
# 我们的 hotplug 脚本与 pin 脚本在这里补齐。
# ---------------------------------------------------------
# cwd = OpenWrt 根，files/ 是 workflow 步骤 6 已拷贝的 overlay
[ -d "files/etc/hotplug.d/net" ] && \
  chmod +x files/etc/hotplug.d/net/* 2>/dev/null || true
[ -f "files/usr/sbin/pin-wifi-cpus.sh" ] && \
  chmod +x files/usr/sbin/pin-wifi-cpus.sh 2>/dev/null || true

# =========================================================
# 10. PPE 硬件转发稳定性修复（C 方案）—— 独立于 NPU 实验
#    来源：wuziwei/ponwrt-ZN504-HG5585F（恩山帖 8497992）
#
#    该作者在同款 AN7581+MT7916 的 HG5585F 上深度调试 PPE 后
#    产出的 8 个补丁，修复上游 airoha_ppe 的真实 bug：
#      931  PON-WAN IPv6 PPPoE 流卸载死锁（L3 误跌 L2 子流 +
#           PPPoE Session ID 被清零 → NPU 端口 6 黑洞）
#      932  网桥 FDB 端口卸载
#      941  NPU 固件信息缓存 + IPv6 SMAC 元数据解码
#      947  LAN/WAN SRAM 拥塞初始化
#      951  网桥 fastpath TTL 保留
#
#    这些修复对「PON-有线」方向的 PPE 硬件转发直接受益，
#    与 NPU 实验无关、默认启用，可用 ADD_PPE_FIXES=false 关闭。
#
#    A 方案（四核亲和脚本 + RPS）不需要构建期处理：
#    files/ overlay 会随固件自动打包。
# =========================================================
if [ "${ADD_PPE_FIXES:-true}" = "true" ]; then
  KVER_P="$(sed -n 's/^KERNEL_PATCHVER:=//p' target/linux/airoha/Makefile 2>/dev/null || echo 6.18)"
  KPATCH_DIR_P="target/linux/airoha/patches-${KVER_P}"
  PPE_FIX_SRC="$GITHUB_WORKSPACE/patches/airoha/ppe-fixes"

  if [ -d "$KPATCH_DIR_P" ] && [ -d "$PPE_FIX_SRC" ]; then
    n=0
    for pf in "$PPE_FIX_SRC"/*.patch; do
      [ -f "$pf" ] || continue
      # 941-01 与 401 / 404 改的是同一段版本查询代码：
      #   · 401 把无条件 if 改成 条件 if + version_check 标签；
      #   · 404 把该 if 包进「等 MIB31 签名 + 重试」循环。
      # 无论走哪条路，941-01 期望的旧上下文都已不存在 → quilt 必然失败
      # （2026-11-26 本地 quilt 全链实测确认）。它只额外提供 fw_version
      # sysfs（读不到时 ENODATA），与 WiFi→PON 转发无关，故一律跳过。
      bname="$(basename "$pf")"
      if [ "$bname" = "941-01-net-airoha-npu-expose-cached-firmware-info.patch" ]; then
        echo "ℹ 跳过 $bname（与 401/404 的版本查询块互斥）"
        continue
      fi
      cp "$pf" "$KPATCH_DIR_P/"
      n=$((n+1))
    done
    echo "✅ PPE 修复补丁已注入：$n 个（931/932/941/947/951 系列）"
    # 注：与 400 的 hunk 不重叠（400 在 wlan_init_memory:539，
    #     941-01 在 regmap_config:722 与 probe:833），可共存
  else
    echo "::warning::PPE 修复补丁未注入（目录缺失：$KPATCH_DIR_P 或 $PPE_FIX_SRC）"
  fi
else
  echo "ℹ ADD_PPE_FIXES != true，跳过 PPE 修复补丁"
fi
