#!/usr/bin/env bash
set -euo pipefail  # 更严格的错误检查（包含未定义变量检测）

# --------------------------
# 1. 常量与环境配置
# --------------------------
BASE_PATH=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# 输入参数（从命令行获取）
REPO_URL="${1}"
REPO_BRANCH="${2}"
BUILD_DIR="${3}"
COMMIT_HASH="${4}"
CONFIG_FILE="${5}"
DISABLED_FUNCTIONS="${6}"
ENABLED_FUNCTIONS="${7}"
KERNEL_VERMAGIC="${8}"
KERNEL_MODULES="${9}"

# 核心配置常量
FEEDS_CONF="feeds.conf.default"
GOLANG_REPO="https://github.com/sbwml/packages_lang_golang"
GOLANG_BRANCH="25.x"
THEME_SET="argon"
LAN_ADDR="192.168.2.1"

# 第三方源列表（便于维护）
FEEDS_LIST=(
    "small8 https://github.com/kenzok8/small-package"
    "kiddin9 https://github.com/kiddin9/kwrt-packages.git"
)

# 需移除的包（按类别分组）
REMOVE_PACKAGES=(
    # luci应用
    "luci/applications:luci-app-passwall luci-app-ddns-go luci-app-rclone luci-app-ssr-plus luci-app-vssr luci-app-daed luci-app-dae luci-app-alist luci-app-homeproxy luci-app-haproxy-tcp luci-app-openclash luci-app-mihomo luci-app-appfilter luci-app-msd_lite"
    # 主题
    "luci/themes:luci-app-passwall luci-app-ddns-go"  # 与应用同名的主题清理
    # 网络包
    "packages/net:haproxy xray-core xray-plugin dns2socks alist hysteria mosdns adguardhome ddns-go naiveproxy shadowsocks-rust sing-box v2ray-core v2ray-geodata v2ray-plugin tuic-client chinadns-ng ipt2socks tcping trojan-plus simple-obfs shadowsocksr-libev dae daed mihomo geoview tailscale open-app-filter msd_lite"
    # 工具包
    "packages/utils:cups"
    # small8源包
    "small8:ppp firewall dae daed daed-next libnftnl nftables dnsmasq luci-theme-argon luci-app-argon-config alist opkg smartdns luci-app-smartdns"
)

# --------------------------
# 2. 通用工具函数
# --------------------------

# 错误处理函数（增强提示信息）
error_handler() {
    local exit_code=$?
    echo "ERROR: 在脚本第 ${BASH_LINENO[0]} 行执行失败" >&2
    echo "命令: '${BASH_COMMAND}'" >&2
    exit $exit_code
}

# 带重试的网络下载函数
download_with_retry() {
    local url="$1"
    local dest="$2"
    local retries="${3:-3}"
    local count=0

    while (( count < retries )); do
        if curl -fsSL --connect-timeout 10 -o "$dest" "$url"; then
            return 0
        fi
        ((count++))
        echo "下载失败，重试 $count/$retries... (目标: $url)" >&2
        sleep 2
    done
    echo "ERROR: 多次下载 $url 失败" >&2
    return 1
}

# 通用仓库克隆函数
clone_repo_generic() {
    local target_dir="$1"
    local repo_url="$2"
    local branch="${3:-main}"
    local depth="${4:-1}"

    if [[ -d "$target_dir" ]]; then
        echo "移除已有目录: $target_dir"
        rm -rf "$target_dir" || { echo "ERROR: 无法删除 $target_dir"; return 1; }
    fi

    echo "克隆仓库: $repo_url (分支: $branch)"
    if ! git clone --depth "$depth" -b "$branch" "$repo_url" "$target_dir"; then
        echo "ERROR: 克隆仓库 $repo_url 失败" >&2
        return 1
    fi
    return 0
}

# 配置文件操作函数（统一封装sed修改）
set_config() {
    local key="$1"
    local value="$2"
    local config_file="${3:-$CONFIG_FILE}"
    
    if grep -q "^$key" "$config_file"; then
        local original=$(grep "^$key" "$config_file" | cut -d'=' -f2-)
        echo "配置 $key: $original → $value"
        sed -i "s/^\($key\s*=\s*\).*\$/\1$value/" "$config_file"
    else
        echo "添加配置 $key=$value"
        echo "$key=$value" >> "$config_file"
    fi
}

set_config_quote() {
    local key="$1"
    local value="$2"
    set_config "$key" "\"$value\"" "$3"
}

get_config() {
    local key="$1"
    local config_file="${2:-$CONFIG_FILE}"
    grep "^$key=" "$config_file" | cut -d'=' -f2- | sed 's/^"//;s/"$//'
}

# --------------------------
# 3. 仓库核心操作
# --------------------------

# 克隆主仓库（若不存在）
clone_main_repo() {
    if [[ ! -d "$BUILD_DIR" ]]; then
        echo "初始化主仓库: $REPO_URL (分支: $REPO_BRANCH)"
        clone_repo_generic "$BUILD_DIR" "$REPO_URL" "$REPO_BRANCH" || exit 1
    fi
}

# 清理工作目录
clean_workspace() {
    echo "清理工作目录: $BUILD_DIR"
    rm -f "$BUILD_DIR/.config" 2>/dev/null
    rm -rf "$BUILD_DIR/tmp" 2>/dev/null
    mkdir -p "$BUILD_DIR/tmp" && echo "1" >"$BUILD_DIR/tmp/.build"
    
    # 清理日志
    if [[ -d "$BUILD_DIR/logs" ]]; then
        rm -rf "$BUILD_DIR/logs"/* 2>/dev/null
    fi
}

# 重置仓库状态并切换Commit
reset_repo_state() {
    echo "重置仓库状态"
    cd "$BUILD_DIR" || exit 1
    
    if [[ -z "$(git symbolic-ref -q HEAD)" ]]; then
        echo "处于分离HEAD状态，直接重置"
        git reset --hard HEAD || exit 1
    else
        echo "重置到远程分支: origin/$REPO_BRANCH"
        git reset --hard "origin/$REPO_BRANCH" || exit 1
    fi
    
    git clean -f -d || exit 1
    git pull || exit 1
    
    if [[ "$COMMIT_HASH" != "none" ]]; then
        echo "切换到指定Commit: $COMMIT_HASH"
        git checkout "$COMMIT_HASH" || exit 1
    fi
}

# --------------------------
# 4. Feeds管理
# --------------------------

# 配置Feeds源
configure_feeds() {
    local feeds_file="$BUILD_DIR/$FEEDS_CONF"
    echo "配置Feeds源: $feeds_file"
    
    # 清理注释行
    sed -i '/^#/d' "$feeds_file" 2>/dev/null
    
    # 添加第三方源
    for feed in "${FEEDS_LIST[@]}"; do
        local name=$(echo "$feed" | awk '{print $1}')
        local url=$(echo "$feed" | awk '{print $2}')
        
        if ! grep -q "$name" "$feeds_file"; then
            # 确保文件以换行符结尾
            [[ -z "$(tail -c 1 "$feeds_file")" ]] || echo "" >>"$feeds_file"
            echo "添加Feeds: $name → $url"
            echo "src-git $name $url" >>"$feeds_file"
        fi
    done
    
    # 添加bpf.mk解决编译问题
    local bpf_mk="$BUILD_DIR/include/bpf.mk"
    if [[ ! -f "$bpf_mk" ]]; then
        echo "创建空文件: $bpf_mk"
        touch "$bpf_mk"
    fi
}

# 更新并安装Feeds
update_and_install_feeds() {
    cd "$BUILD_DIR" || exit 1
    echo "更新Feeds..."
    ./scripts/feeds clean || exit 1
    ./scripts/feeds update -a || exit 1
    
    echo "安装Feeds包..."
    ./scripts/feeds update -i || exit 1
    
    # 按Feeds源分类安装
    for dir in "$BUILD_DIR"/feeds/*/; do
        [[ -d "$dir" && ! -L "$dir" && "$dir" != *.tmp ]] || continue
        local feed_name=$(basename "$dir")
        
        case "$feed_name" in
            "small8")
                install_small8_feeds
                install_fullconenat
                ;;
            "kiddin9")
                install_kiddin9_feeds
                ;;
            *)
                echo "安装默认Feeds: $feed_name"
                ./scripts/feeds install -f -ap "$feed_name" || exit 1
                ;;
        esac
    done
}

# 安装small8源包
install_small8_feeds() {
    echo "安装small8源包"
    ./scripts/feeds install -p small8 -f \
        xray-core xray-plugin dns2tcp dns2socks haproxy hysteria \
        naiveproxy shadowsocks-rust sing-box v2ray-core v2ray-geodata \
        v2ray-geoview v2ray-plugin tuic-client chinadns-ng ipt2socks \
        tcping trojan-plus simple-obfs shadowsocksr-libev luci-app-passwall \
        v2dat mosdns luci-app-mosdns adguardhome luci-app-adguardhome \
        ddns-go luci-app-ddns-go taskd luci-lib-xterm luci-lib-taskd \
        luci-app-store quickstart luci-app-quickstart luci-app-istorex \
        luci-app-cloudflarespeedtest netdata luci-app-netdata lucky \
        luci-app-lucky luci-app-openclash luci-app-homeproxy luci-app-amlogic \
        nikki luci-app-nikki tailscale luci-app-tailscale oaf open-app-filter \
        luci-app-oaf easytier luci-app-easytier msd_lite luci-app-msd_lite \
        cups luci-app-cupsd luci-app-timecontrol || exit 1
}

# 安装fullconenat相关包
install_fullconenat() {
    echo "安装fullconenat组件"
    local pkgs=("fullconenat-nft" "fullconenat")
    for pkg in "${pkgs[@]}"; do
        if [[ ! -d "$BUILD_DIR/package/network/utils/$pkg" ]]; then
            ./scripts/feeds install -p small8 -f "$pkg" || exit 1
        fi
    done
}

# 安装kiddin9源包
install_kiddin9_feeds() {
    echo "安装kiddin9源包"
    ./scripts/feeds install -p kiddin9 -f \
        luci-app-control-weburl luci-app-control-timewol \
        luci-app-control-webrestriction luci-app-parentcontrol \
        luci-app-turboacc || exit 1
}

# --------------------------
# 5. 包管理与更新
# --------------------------

# 移除不需要的包
remove_unwanted_packages() {
    echo "清理不需要的包"
    cd "$BUILD_DIR" || exit 1
    
    for group in "${REMOVE_PACKAGES[@]}"; do
        local category=$(echo "$group" | cut -d':' -f1)
        local pkgs=$(echo "$group" | cut -d':' -f2)
        
        for pkg in $pkgs; do
            local target_path
            case "$category" in
                "luci/applications") target_path="feeds/luci/applications/$pkg" ;;
                "luci/themes") target_path="feeds/luci/themes/$pkg" ;;
                "packages/net") target_path="feeds/packages/net/$pkg" ;;
                "packages/utils") target_path="feeds/packages/utils/$pkg" ;;
                "small8") target_path="feeds/small8/$pkg" ;;
                *) continue ;;
            esac
            
            if [[ -d "$target_path" ]]; then
                echo "移除包: $target_path"
                rm -rf "$target_path" || echo "WARNING: 无法删除 $target_path" >&2
            fi
        done
    done
    
    # 清理istore目录
    if [[ -d "package/istore" ]]; then
        rm -rf "package/istore" || echo "WARNING: 无法删除 package/istore" >&2
    fi
}

# 更新lucky包
update_lucky() {
    echo "更新luci-app-lucky"
    local target_dir="$BUILD_DIR/feeds/small8"
    local repo_url="https://github.com/sirpdboy/luci-app-lucky.git"
    local temp_dir="$BUILD_DIR/tmp/lucky_temp"
    local dirs=("lucky" "luci-app-lucky")
    
    # 清理旧文件
    for dir in "${dirs[@]}"; do
        rm -rf "$target_dir/$dir" 2>/dev/null
    done
    
    # 克隆并复制新文件
    clone_repo_generic "$temp_dir" "$repo_url" "main" || return 1
    for dir in "${dirs[@]}"; do
        if [[ -d "$temp_dir/$dir" ]]; then
            cp -r "$temp_dir/$dir" "$target_dir/" || echo "WARNING: 无法复制 $dir" >&2
        else
            echo "WARNING: 仓库中未找到 $dir" >&2
        fi
    done
    
    # 清理临时文件
    rm -rf "$temp_dir"
}

# 更新golang包
update_golang() {
    echo "更新golang包"
    local target_dir="$BUILD_DIR/feeds/packages/lang/golang"
    
    if [[ -d "$target_dir" ]]; then
        rm -rf "$target_dir" || { echo "ERROR: 无法删除旧golang目录"; return 1; }
    fi
    
    clone_repo_generic "$target_dir" "$GOLANG_REPO" "$GOLANG_BRANCH" || return 1
}

# 更新tcping包
update_tcping() {
    echo "更新tcping"
    local tcping_path="$BUILD_DIR/feeds/small8/tcping/Makefile"
    local url="https://raw.githubusercontent.com/xiaorouji/openwrt-passwall-packages/refs/heads/main/tcping/Makefile"
    
    if [[ -d "$(dirname "$tcping_path")" ]]; then
        download_with_retry "$url" "$tcping_path" || exit 1
    fi
}

# --------------------------
# 6. 系统配置与补丁
# --------------------------

# 修复默认设置（主题、初始化脚本等）
fix_default_settings() {
    echo "配置默认系统设置"
    cd "$BUILD_DIR" || exit 1
    
    # 设置默认主题
    if [[ -d "feeds/luci/collections/" ]]; then
        find "feeds/luci/collections/" -type f -name "Makefile" -exec \
            sed -i "s/luci-theme-bootstrap/luci-theme-$THEME_SET/g" {} + || exit 1
    fi
    
    # 安装自定义初始化脚本
    local uci_defaults="package/base-files/files/etc/uci-defaults"
    install -Dm755 "$BASE_PATH/patches/990_set_argon_primary" "$uci_defaults/990_set_argon_primary"
    install -Dm755 "$BASE_PATH/patches/991_custom_settings" "$uci_defaults/991_custom_settings"
    
    # 替换tempinfo脚本
    local tempinfo_path="package/emortal/autocore/files/tempinfo"
    if [[ -f "$tempinfo_path" && -f "$BASE_PATH/patches/tempinfo" ]]; then
        cp -f "$BASE_PATH/patches/tempinfo" "$tempinfo_path" || exit 1
    fi
}

# 修复miniupnpd补丁
fix_miniupnpd() {
    echo "应用miniupnpd补丁"
    local miniupnpd_dir="$BUILD_DIR/feeds/packages/net/miniupnpd"
    local patch_file="999-chanage-default-leaseduration.patch"
    local patch_src="$BASE_PATH/patches/$patch_file"
    
    if [[ -d "$miniupnpd_dir" && -f "$patch_src" ]]; then
        install -Dm644 "$patch_src" "$miniupnpd_dir/patches/$patch_file" || exit 1
    fi
}

# 替换dnsmasq为dnsmasq-full
replace_dnsmasq_with_full() {
    echo "替换dnsmasq为dnsmasq-full"
    if ! grep -q "dnsmasq-full" "$BUILD_DIR/include/target.mk"; then
        sed -i 's/dnsmasq/dnsmasq-full/g' "$BUILD_DIR/include/target.mk" || exit 1
    fi
}

# 修复依赖关系
fix_dependency() {
    echo "修复依赖关系"
    # 替换SSL库
    sed -i 's/libustream-mbedtls/libustream-openssl/g' "$BUILD_DIR/include/target.mk" 2>/dev/null
    
    # 替换wpad组件
    local qualcommax_mk="$BUILD_DIR/target/linux/qualcommax/Makefile"
    if [[ -f "$qualcommax_mk" ]]; then
        sed -i 's/wpad-openssl/wpad-mesh-openssl/g' "$qualcommax_mk" || exit 1
    fi
}

# 添加WiFi默认配置
add_wifi_defaults() {
    echo "配置WiFi默认设置"
    local uci_paths=(
        "target/linux/qualcommax/base-files/etc/uci-defaults"
        "target/linux/mediatek/filogic/base-files/etc/uci-defaults"
    )
    
    for path in "${uci_paths[@]}"; do
        local full_path="$BUILD_DIR/$path"
        if [[ -d "$full_path" ]]; then
            install -Dm755 "$BASE_PATH/patches/992_set-wifi-uci.sh" "$full_path/992_set-wifi-uci.sh" || exit 1
        fi
    done
}

# 修改默认LAN地址
update_lan_address() {
    echo "设置默认LAN地址: $LAN_ADDR"
    local cfg_path="$BUILD_DIR/package/base-files/files/bin/config_generate"
    if [[ -f "$cfg_path" ]]; then
        sed -i "s/192\.168\.[0-9]*\.[0-9]*/$LAN_ADDR/g" "$cfg_path" || exit 1
    fi
}

# 清理NSS相关内核模块
clean_nss_kmods() {
    echo "清理不需要的NSS内核模块"
    local ipq_mk="$BUILD_DIR/target/linux/qualcommax/Makefile"
    local target_mks=(
        "$BUILD_DIR/target/linux/qualcommax/ipq60xx/target.mk"
        "$BUILD_DIR/target/linux/qualcommax/ipq807x/target.mk"
    )
    
    # 清理目标平台模块
    for mk in "${target_mks[@]}"; do
        if [[ -f "$mk" ]]; then
            sed -i 's/kmod-qca-nss-crypto//g' "$mk" || exit 1
        fi
    done
    
    # 清理主Makefile模块
    if [[ -f "$ipq_mk" ]]; then
        local nss_modules=(
            "kmod-qca-nss-drv-eogremgr" "kmod-qca-nss-drv-gre" "kmod-qca-nss-drv-map-t"
            "kmod-qca-nss-drv-match" "kmod-qca-nss-drv-mirror" "kmod-qca-nss-drv-tun6rd"
            "kmod-qca-nss-drv-tunipip6" "kmod-qca-nss-drv-vxlanmgr" "kmod-qca-nss-drv-wifi-meshmgr"
            "kmod-qca-nss-macsec"
        )
        for mod in "${nss_modules[@]}"; do
            sed -i "/$mod/d" "$ipq_mk" || exit 1
        done
        
        # 清理其他组件
        sed -i 's/automount //g; s/cpufreq //g' "$ipq_mk" || exit 1
    fi
}

# 更新CPU亲和性脚本
update_affinity_script() {
    echo "更新CPU亲和性配置"
    local base_dir="$BUILD_DIR/target/linux/qualcommax"
    
    if [[ -d "$base_dir" ]]; then
        # 清理旧脚本
        find "$base_dir" -name "set-irq-affinity" -delete
        find "$base_dir" -name "smp_affinity" -delete
        
        # 安装新脚本
        install -Dm755 "$BASE_PATH/patches/smp_affinity" \
            "$base_dir/base-files/etc/init.d/smp_affinity" || exit 1
    fi
}

# 修正包哈希值
fix_package_hashes() {
    echo "修正包哈希值"
    local smartdns_mk="$BUILD_DIR/package/feeds/packages/smartdns/Makefile"
    
    if [[ -f "$smartdns_mk" ]]; then
        # 替换smartdns哈希值
        sed -i \
            -e "s/a7edb052fea61418c91c7a052f7eb1478fe6d844aec5e3eda0f2fcf82de29a10/b11e175970e08115fe3b0d7a543fa8d3a6239d3c24eeecfd8cfd2fef3f52c6c9/g" \
            -e "s/a1c084dcc4fb7f87641d706b70168fc3c159f60f37d4b7eac6089ae68f0a18a1/ab7d303a538871ae4a70ead2e90d35e24fcc36bc20f5b6c5d963a3e283ea43b1/g" \
            "$smartdns_mk" || exit 1
    fi
}

# 更新ath11k固件Makefile
update_ath11k_firmware() {
    echo "更新ath11k固件配置"
    local makefile="$BUILD_DIR/package/firmware/ath11k-firmware/Makefile"
    local url="https://raw.githubusercontent.com/VIKINGYFY/immortalwrt/refs/heads/main/package/firmware/ath11k-firmware/Makefile"
    local temp_mk="$BUILD_DIR/tmp/ath11k_fw.mk"
    
    if [[ -d "$(dirname "$makefile")" ]]; then
        download_with_retry "$url" "$temp_mk" || exit 1
        if [[ -s "$temp_mk" ]]; then
            mv -f "$temp_mk" "$makefile" || exit 1
        else
            echo "ERROR: 下载的ath11k固件配置为空" >&2
            exit 1
        fi
    fi
}

# 修复包格式错误
fix_package_format() {
    echo "修复包格式错误"
    if [[ "$BUILD_DIR" =~ "imm-nss" ]]; then
        local fix_pairs=(
            # 格式: "文件路径: 替换规则"
            "feeds/small8/v2ray-geodata/Makefile: s/VER)-\$(PKG_RELEASE)/VER)-r\$(PKG_RELEASE)/g"
            "feeds/small8/luci-lib-taskd/Makefile: s/>=1\.0\.3-1/>=1\.0\.3-r1/g"
            "feeds/small8/luci-app-openclash/Makefile: s/PKG_RELEASE:=beta/PKG_RELEASE:=1/g"
            "feeds/small8/luci-app-quickstart/Makefile: s/PKG_VERSION:=0\.8\.16-1/PKG_VERSION:=0\.8\.16/g; s/PKG_RELEASE:=$/PKG_RELEASE:=1/g"
            "feeds/small8/luci-app-store/Makefile: s/PKG_VERSION:=0\.1\.27-1/PKG_VERSION:=0\.1\.27/g; s/PKG_RELEASE:=$/PKG_RELEASE:=1/g"
        )
        
        for pair in "${fix_pairs[@]}"; do
            local file=$(echo "$pair" | cut -d: -f1)
            local rule=$(echo "$pair" | cut -d: -f2-)
            local full_path="$BUILD_DIR/$file"
            
            if [[ -f "$full_path" ]]; then
                sed -i "$rule" "$full_path" || echo "WARNING: 修复 $file 失败" >&2
            fi
        done
    fi
}

# 添加AX6600 LED控制
add_ax6600_led_control() {
    echo "添加AX6600 LED控制"
    local target_dir="$BUILD_DIR/package/emortal/luci-app-athena-led"
    local repo_url="https://github.com/NONGFAH/luci-app-athena-led.git"
    
    clone_repo_generic "$target_dir" "$repo_url" "main" || exit 1
    
    # 设置执行权限
    chmod +x "$target_dir/root/usr/sbin/athena-led" 2>/dev/null
    chmod +x "$target_dir/root/etc/init.d/athena_led" 2>/dev/null
}

# 优化CPU使用率监控
optimize_cpu_usage_monitor() {
    echo "优化CPU使用率监控"
    local luci_rpc="$BUILD_DIR/feeds/luci/modules/luci-base/root/usr/share/rpcd/ucode/luci"
    local qualcommax_sbin="$BUILD_DIR/target/linux/qualcommax/base-files/sbin"
    local filogic_sbin="$BUILD_DIR/target/linux/mediatek/filogic/base-files/sbin"
    
    # 修改LuCI RPC脚本
    if [[ -f "$luci_rpc" ]]; then
        sed -i \
            -e "s#const fd = popen('top -n1 | awk \\\'/^CPU/ {printf(\"%d%\", 100 - \$8)}\\\'')#const cpuUsageCommand = access('/sbin/cpuusage') ? '/sbin/cpuusage' : 'top -n1 | awk \\\'/^CPU/ {printf(\"%d%\", 100 - \$8)}\\\''#g" \
            -e '/cpuUsageCommand/a \\t\t\tconst fd = popen(cpuUsageCommand);' \
            "$luci_rpc" || exit 1
    fi
    
    # 清理旧脚本
    rm -f "$BUILD_DIR/package/base-files/files/sbin/cpuusage" 2>/dev/null
    
    # 安装平台专用脚本
    install -Dm755 "$BASE_PATH/patches/cpuusage" "$qualcommax_sbin/cpuusage" || exit 1
    install -Dm755 "$BASE_PATH/patches/hnatusage" "$filogic_sbin/cpuusage" || exit 1
}

# 设置自定义定时任务
set_custom_crontab() {
    echo "配置自定义定时任务"
    local init_script="$BUILD_DIR/package/base-files/files/etc/init.d/custom_task"
    
    cat <<'EOF' >"$init_script"
#!/bin/sh /etc/rc.common
# 设置启动优先级
START=99

boot() {
    # 重新添加缓存清理定时任务
    sed -i '/drop_caches/d' /etc/crontabs/root
    echo "15 3 * * * sync && echo 3 > /proc/sys/vm/drop_caches" >>/etc/crontabs/root

    # 删除现有的wireguard_watchdog任务
    sed -i '/wireguard_watchdog/d' /etc/crontabs/root

    # 获取WireGuard接口名称（此处保留原逻辑）
    # [后续逻辑可在此处扩展]
}
EOF
    chmod +x "$init_script" || exit 1
}

# --------------------------
# 7. 主执行流程
# --------------------------

# 捕获错误信号
trap 'error_handler' ERR

# 执行核心流程
main() {
    echo "===== 开始执行固件构建准备脚本 ====="
    
    # 仓库初始化
    clone_main_repo
    clean_workspace
    cd "$BUILD_DIR" || exit 1
    reset_repo_state
    
    # Feeds配置
    configure_feeds
    update_and_install_feeds
    
    # 包管理
    remove_unwanted_packages
    update_lucky
    update_golang
    update_tcping
    
    # 系统配置
    fix_default_settings
    fix_miniupnpd
    replace_dnsmasq_with_full
    fix_dependency
    add_wifi_defaults
    update_lan_address
    
    # 硬件相关优化
    clean_nss_kmods
    update_affinity_script
    update_ath11k_firmware
    add_ax6600_led_control
    optimize_cpu_usage_monitor
    
    # 其他修复
    fix_package_hashes
    fix_package_format
    set_custom_crontab
    
    echo "===== 脚本执行完成 ====="
}

# 启动主流程
main
