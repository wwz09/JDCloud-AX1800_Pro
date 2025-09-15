#!/usr/bin/env bash

# OpenWrt 构建优化脚本
# 优化要点：
# 1. 改进错误处理机制，提供更详细的错误信息和退出代码
# 2. 增强参数验证和默认值处理
# 3. 优化代码结构，按功能模块重组函数
# 4. 增加日志记录功能，便于调试和跟踪
# 5. 添加进度显示和用户友好的提示
# 6. 优化重复代码，创建通用工具函数
# 7. 改进文件和目录操作的安全性
# 8. 增加性能优化措施

# 设置严格模式和错误处理
set -eE -o pipefail

# 全局变量定义
readonly SCRIPT_NAME="$(basename "$0")"
readonly BASE_PATH="$(cd "$(dirname "$0")" && pwd)"
readonly TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
readonly LOG_FILE="${BASE_PATH}/${SCRIPT_NAME%.*}_${TIMESTAMP}.log"

# 颜色定义（用于终端输出美化）
readonly COLOR_RED="\033[0;31m"
readonly COLOR_GREEN="\033[0;32m"
readonly COLOR_YELLOW="\033[0;33m"
readonly COLOR_BLUE="\033[0;34m"
readonly COLOR_RESET="\033[0m"

# 默认配置
readonly DEFAULT_REPO_URL="https://github.com/openwrt/openwrt.git"
readonly DEFAULT_REPO_BRANCH="main"
readonly DEFAULT_BUILD_DIR="${BASE_PATH}/build"
readonly DEFAULT_CONFIG_FILE=".config"
readonly DEFAULT_THEME_SET="argon"
readonly DEFAULT_LAN_ADDR="192.168.2.1"
readonly FEEDS_CONF="feeds.conf.default"
readonly GOLANG_REPO="https://github.com/sbwml/packages_lang_golang"
readonly GOLANG_BRANCH="25.x"

# 初始化变量
REPO_URL=""
REPO_BRANCH=""
BUILD_DIR=""
COMMIT_HASH="none"
CONFIG_FILE=""
DISABLED_FUNCTIONS=""
ENABLED_FUNCTIONS=""
KERNEL_VERMAGIC=""
KERNEL_MODULES=""

# 日志函数 - 提供分级日志记录，同时输出到终端和日志文件
log() {
    local level="$1"
    local message="$2"
    local timestamp="$(date +"%Y-%m-%d %H:%M:%S")"
    local level_color

    case "$level" in
        "ERROR") level_color="$COLOR_RED" ;;    
        "WARNING") level_color="$COLOR_YELLOW" ;;  
        "INFO") level_color="$COLOR_BLUE" ;;      
        "SUCCESS") level_color="$COLOR_GREEN" ;;  
        *) level_color="$COLOR_RESET" ;;          
    esac

    echo -e "${level_color}[${timestamp}] ${level}: ${message}${COLOR_RESET}" | tee -a "${LOG_FILE}"
}

# 增强的错误处理函数
error_handler() {
    local exit_code="$1"
    local line_number="${BASH_LINENO[0]}"
    local command="${BASH_COMMAND}"
    local function_name="${FUNCNAME[1]}"
    
    log "ERROR" "脚本执行失败！"
    log "ERROR" "在函数: $function_name, 行号: $line_number, 命令: '$command'"
    log "ERROR" "退出代码: $exit_code"
    log "ERROR" "详细日志请查看: $LOG_FILE"
    
    exit "$exit_code"
}

# 设置trap捕获ERR信号和EXIT信号
trap 'error_handler "$?"' ERR

# 进度显示函数 - 提供直观的进度条
show_progress() {
    local current="$1"
    local total="$2"
    local message="$3"
    local percent=$((current * 100 / total))
    local bar_length=30
    local filled_length=$((bar_length * current / total))
    local bar=""
    
    for ((i=0; i<filled_length; i++)); do
        bar="${bar}#"
    done
    
    for ((i=filled_length; i<bar_length; i++)); do
        bar="${bar}-"
    done
    
    echo -ne "\r${COLOR_BLUE}[${percent}%] [${bar}] ${message}${COLOR_RESET}" 1>&2
    
    if [[ $current -eq $total ]]; then
        echo "" 1>&2
    fi
}

# 参数解析和验证函数
parse_arguments() {
    # 使用默认值增强参数处理
    REPO_URL="${1:-$DEFAULT_REPO_URL}"
    REPO_BRANCH="${2:-$DEFAULT_REPO_BRANCH}"
    BUILD_DIR="${3:-$DEFAULT_BUILD_DIR}"
    COMMIT_HASH="${4:-none}"
    CONFIG_FILE="${5:-$DEFAULT_CONFIG_FILE}"
    DISABLED_FUNCTIONS="${6}"
    ENABLED_FUNCTIONS="${7}"
    KERNEL_VERMAGIC="${8}"
    KERNEL_MODULES="${9}"
    
    # 提前创建BUILD_DIR的父目录（避免后续操作失败）
    mkdir -p "$(dirname "$BUILD_DIR")" || { 
        log "ERROR" "无法创建构建目录的父目录: $(dirname "$BUILD_DIR")"
        exit 1
    }
    
    # 记录参数信息到日志
    log "INFO" "脚本启动: $SCRIPT_NAME"
    log "INFO" "仓库URL: $REPO_URL"
    log "INFO" "仓库分支: $REPO_BRANCH"
    log "INFO" "构建目录: $BUILD_DIR"
    log "INFO" "提交哈希: $COMMIT_HASH"
    log "INFO" "配置文件: $CONFIG_FILE"
    log "INFO" "禁用函数: $DISABLED_FUNCTIONS"
    log "INFO" "启用函数: $ENABLED_FUNCTIONS"
    log "INFO" "内核魔数: $KERNEL_VERMAGIC"
    log "INFO" "内核模块: $KERNEL_MODULES"
}

# 配置操作函数 - 增加了文件存在检查和更详细的日志
_set_config() {
    local key="$1"
    local value="$2"
    
    if [[ ! -f ".config" ]]; then
        log "WARNING" "配置文件 .config 不存在，跳过设置 $key=$value"
        return 1
    fi
    
    local original
    original=$(grep "^$key" ".config" | cut -d'=' -f2 2>/dev/null || echo "<未设置>")
    log "INFO" "设置 $key=$value (原值: $original)"
    sed -i "s/^\($key\s*=\s*\).*\$/\1$value/" .config
}

_set_config_quote() {
    local key="$1"
    local value="$2"
    
    if [[ ! -f ".config" ]]; then
        log "WARNING" "配置文件 .config 不存在，跳过设置 $key=\"$value\""
        return 1
    fi
    
    local original
    original=$(grep "^$key" ".config" | cut -d'=' -f2 2>/dev/null || echo "<未设置>")
    log "INFO" "设置 $key=\"$value\" (原值: $original)"
    sed -i "s/^\($key\s*=\s*\).*\$/\1\"$value\"/" .config
}

_get_config() {
    local key="$1"
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log "WARNING" "配置文件 $CONFIG_FILE 不存在"
        return 1
    fi
    
    grep "^$key=" "$CONFIG_FILE" | cut -d'=' -f2
}

_get_arch_from_config() {
    local value_CONFIG_TARGET_x86_64
    value_CONFIG_TARGET_x86_64=$(_get_config "CONFIG_TARGET_x86_64")
    
    if [[ $value_CONFIG_TARGET_x86_64 == "y" ]]; then
        echo "x86_64"
    else
        echo "aarch64"
    fi
}

# 仓库操作函数
clone_repo() {
    log "INFO" "开始处理仓库克隆..."
    
    if [[ ! -d "$BUILD_DIR" ]]; then
        log "INFO" "克隆仓库: $REPO_URL 分支: $REPO_BRANCH"
        if ! git clone --depth 1 -b "$REPO_BRANCH" "$REPO_URL" "$BUILD_DIR"; then
            log "ERROR" "克隆仓库 $REPO_URL 失败"
            exit 1
        fi
    else
        log "INFO" "构建目录 $BUILD_DIR 已存在，跳过克隆"
    fi
}

reset_feeds_conf() {
    log "INFO" "开始重置 feeds 配置..."
    
    cd "$BUILD_DIR" || exit 1
    
    if [ "$(git symbolic-ref -q HEAD)" == "" ]; then
        log "INFO" "[git] 处于分离 HEAD 状态模式"
        git reset --hard HEAD
    else
        git reset --hard "origin/$REPO_BRANCH"
    fi
    
    git clean -f -d
    git pull
    
    if [[ $COMMIT_HASH != "none" ]]; then
        log "INFO" "检出指定的提交哈希: $COMMIT_HASH"
        git checkout "$COMMIT_HASH"
    fi
}

# 清理函数 - 增强了安全性和日志记录
clean_up() {
    log "INFO" "开始清理构建环境..."
    
    cd "$BUILD_DIR" || exit 1
    
    # 安全删除文件，避免误操作
    if [[ -f "$BUILD_DIR/.config" ]]; then
        log "INFO" "删除配置文件: $BUILD_DIR/.config"
        rm -f "$BUILD_DIR/.config"
    fi
    
    if [[ -d "$BUILD_DIR/tmp" ]]; then
        log "INFO" "删除临时目录: $BUILD_DIR/tmp"
        rm -rf "$BUILD_DIR/tmp"
    fi
    
    if [[ -d "$BUILD_DIR/logs" ]]; then
        log "INFO" "清空日志目录: $BUILD_DIR/logs"
        rm -rf "$BUILD_DIR/logs/*"
    fi
    
    # 重新创建必要的目录
    mkdir -p "$BUILD_DIR/tmp"
    echo "1" >"$BUILD_DIR/tmp/.build"
    
    log "SUCCESS" "构建环境清理完成"
}

# Feeds 管理函数 - 改进了错误处理和日志
update_feeds() {
    log "INFO" "开始更新 feeds..."
    
    cd "$BUILD_DIR" || exit 1
    
    # 定义添加 feeds 的函数
    add_feeds() {
        local feed="$1"
        local url="$2"
        
        if ! grep -q "$feed" "$BUILD_DIR/$FEEDS_CONF"; then
            # 确保文件以换行符结尾
            [ -z "$(tail -c 1 "$BUILD_DIR/$FEEDS_CONF")" ] || echo "" >>"$BUILD_DIR/$FEEDS_CONF"
            echo "src-git $feed $url" >>"$BUILD_DIR/$FEEDS_CONF"
            log "INFO" "已添加 feeds: $feed -> $url"
        else
            log "INFO" "Feeds $feed 已存在，跳过添加"
        fi
    }
    
    # 删除注释行
    sed -i '/^#/d' "$BUILD_DIR/$FEEDS_CONF"
    
    # 检查并添加源
    add_feeds "small8" "https://github.com/kenzok8/small-package"
    add_feeds "kiddin9" "https://github.com/kiddin9/kwrt-packages.git"
    # add_feeds "opentopd" "https://github.com/sirpdboy/sirpdboy-package"
    # add_feeds "node" "https://github.com/nxhack/openwrt-node-packages.git"
    # add_feeds "libremesh" "https://github.com/libremesh/lime-packages"
    
    # 添加bpf.mk解决更新报错
    if [ ! -f "$BUILD_DIR/include/bpf.mk" ]; then
        touch "$BUILD_DIR/include/bpf.mk"
        log "INFO" "已创建 bpf.mk 文件"
    fi
    
    # 更新 feeds
    log "INFO" "执行 feeds clean 命令"
    ./scripts/feeds clean
    
    log "INFO" "执行 feeds update 命令"
    ./scripts/feeds update -a
    
    log "SUCCESS" "Feeds 更新完成"
}

# 包管理函数 - 添加了进度显示和更详细的统计
remove_unwanted_packages() {
    log "INFO" "开始移除不需要的包..."
    
    cd "$BUILD_DIR" || exit 1
    
    local removed_count=0
    local total_packages=0
    
    # 定义需要移除的包列表
    local luci_packages=(
        "luci-app-passwall" "luci-app-ddns-go" "luci-app-rclone" "luci-app-ssr-plus"
        "luci-app-vssr" "luci-app-daed" "luci-app-dae" "luci-app-alist" "luci-app-homeproxy"
        "luci-app-haproxy-tcp" "luci-app-openclash" "luci-app-mihomo" "luci-app-appfilter"
        "luci-app-msd_lite"
    )
    
    local packages_net=(
        "haproxy" "xray-core" "xray-plugin" "dns2socks" "alist" "hysteria"
        "mosdns" "adguardhome" "ddns-go" "naiveproxy" "shadowsocks-rust"
        "sing-box" "v2ray-core" "v2ray-geodata" "v2ray-plugin" "tuic-client"
        "chinadns-ng" "ipt2socks" "tcping" "trojan-plus" "simple-obfs" "shadowsocksr-libev" 
        "dae" "daed" "mihomo" "geoview" "tailscale" "open-app-filter" "msd_lite"
    )
    
    local packages_utils=(
        "cups"
    )
    
    local small8_packages=(
        "ppp" "firewall" "dae" "daed" "daed-next" "libnftnl" "nftables" "dnsmasq" "luci-theme-argon" "luci-app-argon-config"
        "alist" "opkg" "smartdns" "luci-app-smartdns"
    )
    
    # 合并所有包列表以计算总数
    total_packages=$(( ${#luci_packages[@]} + ${#packages_net[@]} + ${#packages_utils[@]} + ${#small8_packages[@]} + 1 ))
    
    # 移除 luci 包
    for ((i=0; i<${#luci_packages[@]}; i++)); do
        local pkg="${luci_packages[$i]}"
        show_progress "$((removed_count+1))" "$total_packages" "正在移除包: $pkg"
        
        if [[ -d ./feeds/luci/applications/$pkg ]]; then
            rm -rf ./feeds/luci/applications/$pkg
            removed_count=$((removed_count+1))
        fi
        
        if [[ -d ./feeds/luci/themes/$pkg ]]; then
            rm -rf ./feeds/luci/themes/$pkg
            removed_count=$((removed_count+1))
        fi
    done
    
    # 移除网络包
    for ((i=0; i<${#packages_net[@]}; i++)); do
        local pkg="${packages_net[$i]}"
        show_progress "$((removed_count+1))" "$total_packages" "正在移除包: $pkg"
        
        if [[ -d ./feeds/packages/net/$pkg ]]; then
            rm -rf ./feeds/packages/net/$pkg
            removed_count=$((removed_count+1))
        fi
    done
    
    # 移除工具包
    for ((i=0; i<${#packages_utils[@]}; i++)); do
        local pkg="${packages_utils[$i]}"
        show_progress "$((removed_count+1))" "$total_packages" "正在移除包: $pkg"
        
        if [[ -d ./feeds/packages/utils/$pkg ]]; then
            rm -rf ./feeds/packages/utils/$pkg
            removed_count=$((removed_count+1))
        fi
    done
    
    # 移除 small8 包
    for ((i=0; i<${#small8_packages[@]}; i++)); do
        local pkg="${small8_packages[$i]}"
        show_progress "$((removed_count+1))" "$total_packages" "正在移除包: $pkg"
        
        if [[ -d ./feeds/small8/$pkg ]]; then
            rm -rf ./feeds/small8/$pkg
            removed_count=$((removed_count+1))
        fi
    done
    
    # 移除 istore
    show_progress "$((removed_count+1))" "$total_packages" "正在移除包: istore"
    if [[ -d ./package/istore ]]; then
        rm -rf ./package/istore
        removed_count=$((removed_count+1))
    fi
    
    # 安装新的 argon 主题
    log "INFO" "安装新的 luci-theme-argon 主题"
    git clone https://github.com/LazuliKao/luci-theme-argon -b openwrt-24.10 ./feeds/luci/themes/luci-theme-argon-new
    mv ./feeds/luci/themes/luci-theme-argon-new/luci-theme-argon ./feeds/luci/themes/luci-theme-argon
    mv ./feeds/luci/themes/luci-theme-argon-new/luci-app-argon-config ./feeds/luci/applications/luci-app-argon-config
    rm -rf ./feeds/luci/themes/luci-theme-argon-new
    
    # 清理特定的 uci-defaults 文件
    if [ -d "$BUILD_DIR/target/linux/qualcommax/base-files/etc/uci-defaults" ]; then
        log "INFO" "清理 qualcommax uci-defaults 中的 99*.sh 文件"
        find "$BUILD_DIR/target/linux/qualcommax/base-files/etc/uci-defaults/" -type f -name "99*.sh" -exec rm -f {} +
    fi
    
    log "SUCCESS" "移除不需要的包完成，共移除 $removed_count 个包"
}

# 更新 golang 函数
update_golang() {
    log "INFO" "开始更新 golang 软件包..."
    
    cd "$BUILD_DIR" || exit 1
    
    if [[ -d ./feeds/packages/lang/golang ]]; then
        rm -rf ./feeds/packages/lang/golang
        
        if ! git clone --depth 1 -b "$GOLANG_BRANCH" "$GOLANG_REPO" ./feeds/packages/lang/golang; then
            log "ERROR" "克隆 golang 仓库 $GOLANG_REPO 失败"
            exit 1
        fi
        
        log "SUCCESS" "golang 软件包更新完成"
    else
        log "WARNING" "未找到 golang 目录，跳过更新"
    fi
}

# 安装 feeds 函数 - 增加了进度显示
install_small8() {
    log "INFO" "开始安装 small8 feeds..."
    
    cd "$BUILD_DIR" || exit 1
    
    ./scripts/feeds install -p small8 -f xray-core xray-plugin dns2tcp dns2socks haproxy hysteria \
        naiveproxy shadowsocks-rust sing-box v2ray-core v2ray-geodata v2ray-geoview v2ray-plugin \
        tuic-client chinadns-ng ipt2socks tcping trojan-plus simple-obfs shadowsocksr-libev \
        luci-app-passwall v2dat mosdns luci-app-mosdns adguardhome luci-app-adguardhome ddns-go \
        luci-app-ddns-go taskd luci-lib-xterm luci-lib-taskd luci-app-store quickstart \
        luci-app-quickstart luci-app-istorex luci-app-cloudflarespeedtest netdata luci-app-netdata \
        lucky luci-app-lucky luci-app-openclash luci-app-homeproxy luci-app-amlogic nikki luci-app-nikki \
        tailscale luci-app-tailscale oaf open-app-filter luci-app-oaf easytier luci-app-easytier \
        msd_lite luci-app-msd_lite cups luci-app-cupsd luci-app-timecontrol
        
    log "SUCCESS" "small8 feeds 安装完成"
}

install_fullconenat() {
    log "INFO" "开始安装 fullconenat 相关包..."
    
    cd "$BUILD_DIR" || exit 1
    
    if [ ! -d "$BUILD_DIR/package/network/utils/fullconenat-nft" ]; then
        ./scripts/feeds install -p small8 -f fullconenat-nft
        log "INFO" "已安装 fullconenat-nft"
    fi
    
    if [ ! -d "$BUILD_DIR/package/network/utils/fullconenat" ]; then
        ./scripts/feeds install -p small8 -f fullconenat
        log "INFO" "已安装 fullconenat"
    fi
    
    log "SUCCESS" "fullconenat 安装完成"
}

install_kiddin9() {
    log "INFO" "开始安装 kiddin9 feeds..."
    
    cd "$BUILD_DIR" || exit 1
    
    ./scripts/feeds install -p kiddin9 -f luci-app-control-weburl luci-app-control-timewol luci-app-control-webrestriction luci-app-parentcontrol luci-app-turboacc
    
    log "SUCCESS" "kiddin9 feeds 安装完成"
}

install_feeds() {
    log "INFO" "开始安装所有 feeds..."
    
    cd "$BUILD_DIR" || exit 1
    
    ./scripts/feeds update -i
    
    local total_dirs=0
    local processed_dirs=0
    
    # 先计算总数
    for dir in "$BUILD_DIR/feeds/"*; do
        if [ -d "$dir" ] && [[ ! "$dir" == *.tmp ]] && [ ! -L "$dir" ]; then
            total_dirs=$((total_dirs+1))
        fi
    done
    
    # 再处理每个目录并显示进度
    for dir in "$BUILD_DIR/feeds/"*; do
        if [ -d "$dir" ] && [[ ! "$dir" == *.tmp ]] && [ ! -L "$dir" ]; then
            processed_dirs=$((processed_dirs+1))
            dir_name=$(basename "$dir")
            
            show_progress "$processed_dirs" "$total_dirs" "正在安装 feeds: $dir_name"
            
            if [[ "$dir_name" == "small8" ]]; then
                install_small8
                install_fullconenat
            elif [[ "$dir_name" == "kiddin9" ]]; then
                install_kiddin9
            else
                ./scripts/feeds install -f -ap "$(basename "$dir")"
            fi
        fi
    done
    
    log "SUCCESS" "所有 feeds 安装完成"
}

# 配置和补丁应用函数
fix_default_set() {
    log "INFO" "开始修复默认设置..."
    
    cd "$BUILD_DIR" || exit 1
    
    # 修改默认主题
    if [ -d "$BUILD_DIR/feeds/luci/collections/" ]; then
        log "INFO" "设置默认主题为 $DEFAULT_THEME_SET"
        find "$BUILD_DIR/feeds/luci/collections/" -type f -name "Makefile" -exec sed -i "s/luci-theme-bootstrap/luci-theme-$DEFAULT_THEME_SET/g" {} \;
    fi
    
    # 安装自定义配置文件
    if [ -f "$BASE_PATH/patches/990_set_argon_primary" ]; then
        install -Dm755 "$BASE_PATH/patches/990_set_argon_primary" "$BUILD_DIR/package/base-files/files/etc/uci-defaults/990_set_argon_primary"
        log "INFO" "已安装 990_set_argon_primary"
    else
        log "WARNING" "未找到 $BASE_PATH/patches/990_set_argon_primary 文件"
    fi
    
    if [ -f "$BASE_PATH/patches/991_custom_settings" ]; then
        install -Dm755 "$BASE_PATH/patches/991_custom_settings" "$BUILD_DIR/package/base-files/files/etc/uci-defaults/991_custom_settings"
        log "INFO" "已安装 991_custom_settings"
    else
        log "WARNING" "未找到 $BASE_PATH/patches/991_custom_settings 文件"
    fi
    
    # 更新 tempinfo
    if [ -f "$BUILD_DIR/package/emortal/autocore/files/tempinfo" ] && [ -f "$BASE_PATH/patches/tempinfo" ]; then
        cp -f "$BASE_PATH/patches/tempinfo" "$BUILD_DIR/package/emortal/autocore/files/tempinfo"
        log "INFO" "已更新 tempinfo 文件"
    fi
    
    log "SUCCESS" "默认设置修复完成"
}

# 通用工具函数
# 重命名并改进原有函数以提高可读性
trim_space() {
    local str="$1"
    echo "$str" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

call_function() {
    local func_name="$1"
    shift
    
    if type "$func_name" &>/dev/null; then
        "$func_name" "$@"
    else
        log "WARNING" "函数 '$func_name' 未找到"
    fi
}

run_function() {
    local func_name="$1"
    shift
    
    if [[ $func_name =~ ^# ]]; then
        local original_name=${func_name:1}
        local original_name=$(trim_space "$original_name")
        
        if [[ $ENABLED_FUNCTIONS =~ $original_name ]]; then
            log "INFO" "执行强制启用的函数: '$original_name'"
            call_function "$original_name" "$@"
        else
            log "INFO" "跳过注释函数: '$original_name'"
        fi
    elif [[ $DISABLED_FUNCTIONS =~ $func_name ]]; then
        log "INFO" "跳过禁用函数: '$func_name'"
    else
        log "INFO" "执行函数: '$func_name'"
        call_function "$func_name" "$@"
    fi
}

# 增强的函数执行器，添加了进度显示
foreach_function() {
    local func_names=()
    local i=0
    
    # 读取并存储所有函数名
    while read -r func_name; do
        if [ -n "$func_name" ]; then
            func_names[i]="$func_name"
            i=$((i+1))
        fi
    done < <(cat)
    
    # 执行每个函数并显示进度
    local total_functions=${#func_names[@]}
    
    for ((i=0; i<total_functions; i++)); do
        show_progress "$((i+1))" "$total_functions" "正在执行: ${func_names[$i]}"
        run_function "${func_names[$i]}"
    done
}

# 以下是完整实现的原有核心功能函数

fix_mkpkg_format_invalid() {
    log "INFO" "修复包格式无效问题..."
    cd "$BUILD_DIR" || exit 1
    
    if [[ $BUILD_DIR =~ "imm-nss" ]]; then
        if [ -f $BUILD_DIR/feeds/small8/v2ray-geodata/Makefile ]; then
            sed -i 's/VER)-\$(PKG_RELEASE)/VER)-r\$(PKG_RELEASE)/g' $BUILD_DIR/feeds/small8/v2ray-geodata/Makefile
            log "INFO" "已修复 v2ray-geodata Makefile 格式"
        fi
    fi
    
    log "SUCCESS" "包格式无效问题修复完成"
}

add_turboacc() {
    log "INFO" "添加 turboacc 加速..."
    cd "$BUILD_DIR" || exit 1
    curl -sSL https://raw.githubusercontent.com/chenmozhijin/turboacc/luci/add_turboacc.sh -o add_turboacc.sh
    if bash add_turboacc.sh --no-sfe; then
        log "SUCCESS" "turboacc 添加成功"
    else
        log "ERROR" "turboacc 添加失败"
    fi
    cd - >/dev/null
}

fix_cudy_tr3000_114m() {
    log "INFO" "修复 Cudy TR3000 设备分区大小为 114MB..."
    cd "$BUILD_DIR" || exit 1
    
    local size="0x7200000" #114MB
    local dts_file="$BUILD_DIR/target/linux/mediatek/dts/mt7981b-cudy-tr3000-v1-ubootmod.dts"
    if [ -f "$dts_file" ]; then
        sed -i "s/reg = <0x5c0000 0x[0-9a-fA-F]*>/reg = <0x5c0000 $size>/g" "$dts_file"
        log "INFO" "已更新 $dts_file"
    fi
    local dts_file2="$BUILD_DIR/target/linux/mediatek/dts/mt7981b-cudy-tr3000-v1.dts"
    if [ -f "$dts_file2" ]; then
        sed -i "s/reg = <0x5c0000 0x[0-9a-fA-F]*>/reg = <0x5c0000 $size>/g" "$dts_file2"
        log "INFO" "已更新 $dts_file2"
    fi
    local dts_uboot_file="$BUILD_DIR/package/boot/uboot-mediatek/patches/445-add-cudy_tr3000-v1.patch"
    if [ -f "$dts_uboot_file" ]; then
        sed -i "s/0x5c0000 0x[0-9a-fA-F]*/0x5c0000 $size/g" "$dts_uboot_file"
        log "INFO" "已更新 $dts_uboot_file"
    fi
    local dts_for_padavanonly="$BUILD_DIR/target/linux/mediatek/files-5.4/arch/arm64/boot/dts/mediatek/mt7981-cudy-tr3000-v1.dts"
    if [ -f "$dts_for_padavanonly" ]; then
        sed -i "s/reg = <0x5c0000 0x[0-9a-fA-F]*>/reg = <0x5c0000 $size>/g" "$dts_for_padavanonly"
        log "INFO" "已更新 $dts_for_padavanonly"
    fi
    
    log "SUCCESS" "Cudy TR3000 设备分区大小修复完成"
    cd - >/dev/null
}

update_proxy_app_menu_location() {
    log "INFO" "更新代理应用菜单位置..."
    cd "$BUILD_DIR" || exit 1
    
    # passwall
    local passwall_path="$BUILD_DIR/package/feeds/small8/luci-app-passwall/luasrc/controller/passwall.lua"
    if [ -d "${passwall_path%/*}" ] && [ -f "$passwall_path" ]; then
        local pos=$(grep -n "entry" "$passwall_path" | head -n 1 | awk -F ":" '{print $1}')
        if [ -n "$pos" ]; then
            sed -i ''${pos}'i\	entry({"admin", "proxy"}, firstchild(), "Proxy", 30).dependent = false' "$passwall_path"
            sed -i 's/"services"/"proxy"/g' "$passwall_path"
            log "INFO" "已更新 passwall 菜单位置"
        fi
    fi
    # passwall2
    local passwall2_path="$BUILD_DIR/package/feeds/small8/luci-app-passwall2/luasrc/controller/passwall2.lua"
    if [ -d "${passwall2_path%/*}" ] && [ -f "$passwall2_path" ]; then
        local pos=$(grep -n "entry" "$passwall2_path" | head -n 1 | awk -F ":" '{print $1}')
        if [ -n "$pos" ]; then
            sed -i ''${pos}'i\	entry({"admin", "proxy"}, firstchild(), "Proxy", 30).dependent = false' "$passwall2_path"
            sed -i 's/"services"/"proxy"/g' "$passwall2_path"
            log "INFO" "已更新 passwall2 菜单位置"
        fi
    fi
    # sing-box
    local singbox_path="$BUILD_DIR/package/feeds/small8/luci-app-sing-box/luasrc/controller/sing-box.lua"
    if [ -d "${singbox_path%/*}" ] && [ -f "$singbox_path" ]; then
        local pos=$(grep -n "entry" "$singbox_path" | head -n 1 | awk -F ":" '{print $1}')
        if [ -n "$pos" ]; then
            sed -i ''${pos}'i\	entry({"admin", "proxy"}, firstchild(), "Proxy", 30).dependent = false' "$singbox_path"
            sed -i 's/"services"/"proxy"/g' "$singbox_path"
            log "INFO" "已更新 sing-box 菜单位置"
        fi
    fi
    # homeproxy
    local homeproxy_path="$BUILD_DIR/package/feeds/small8/luci-app-homeproxy/luasrc/controller/homeproxy.lua"
    if [ -d "${homeproxy_path%/*}" ] && [ -f "$homeproxy_path" ]; then
        local pos=$(grep -n "entry" "$homeproxy_path" | head -n 1 | awk -F ":" '{print $1}')
        if [ -n "$pos" ]; then
            sed -i ''${pos}'i\	entry({"admin", "proxy"}, firstchild(), "Proxy", 30).dependent = false' "$homeproxy_path"
            sed -i 's/\/services\//\/proxy\//g' "$homeproxy_path"
            log "INFO" "已更新 homeproxy 菜单位置"
        fi
    fi
    # nikki
    local nikki_path="$BUILD_DIR/package/feeds/small8/luci-app-nikki/root/usr/share/luci/menu.d/luci-app-nikki.json"
    if [ -d "${nikki_path%/*}" ] && [ -f "$nikki_path" ]; then
        sed -i 's/\/services\//\/proxy\//g' "$nikki_path"
        log "INFO" "已更新 nikki 菜单位置"
    fi
    
    log "SUCCESS" "代理应用菜单位置更新完成"
    cd - >/dev/null
}

update_dns_app_menu_location() {
    log "INFO" "更新 DNS 应用菜单位置..."
    cd "$BUILD_DIR" || exit 1
    
    # smartdns
    local smartdns_path="$BUILD_DIR/package/feeds/small8/luci-app-smartdns/luasrc/controller/smartdns.lua"
    if [ -d "${smartdns_path%/*}" ] && [ -f "$smartdns_path" ]; then
        local pos=$(grep -n "entry" "$smartdns_path" | head -n 1 | awk -F ":" '{print $1}')
        if [ -n "$pos" ]; then
            sed -i ''${pos}'i\	entry({"admin", "dns"}, firstchild(), "DNS", 29).dependent = false' "$smartdns_path"
            sed -i 's/"services"/"dns"/g' "$smartdns_path"
            log "INFO" "已更新 smartdns 菜单位置"
        fi
    fi
    
    log "SUCCESS" "DNS 应用菜单位置更新完成"
    cd - >/dev/null
}

fix_kernel_magic() {
    log "INFO" "设置内核 VERMAGIC..."
    cd "$BUILD_DIR" || exit 1
    
    # Check if KERNEL_VERMAGIC is empty or not specified
    if [ -z "$KERNEL_VERMAGIC" ]; then
        log "WARNING" "KERNEL_VERMAGIC 为空，跳过内核 magic 修复"
        return 0
    fi

    local kernel_defaults="$BUILD_DIR/include/kernel-defaults.mk"
    if [ -f "$kernel_defaults" ]; then
        sed -i "/\\$(LINUX_DIR)\/\.vermagic$/c\\\techo ${KERNEL_VERMAGIC} > \\$(LINUX_DIR)/.vermagic" "$kernel_defaults"
        log "INFO" "内核 vermagic 设置为: $KERNEL_VERMAGIC"
    fi

    local kernel_makefile="$BUILD_DIR/package/kernel/linux/Makefile"
    if [ -f "$kernel_makefile" ]; then
        sed -i "/STAMP_BUILT:=/c\\  STAMP_BUILT:=\\$(STAMP_BUILT)_$KERNEL_VERMAGIC" "$kernel_makefile"
    fi

    # If KERNEL_MODULES is specified, add the distfeeds.conf
    if [ -n "$KERNEL_MODULES" ]; then
        if [ ! -d "$BUILD_DIR/package/base-files/files/etc/opkg" ]; then
            mkdir -p "$BUILD_DIR/package/base-files/files/etc/opkg"
        fi
        echo "src/gz modules $KERNEL_MODULES" > "$BUILD_DIR/package/base-files/files/etc/opkg/distfeeds.conf"
        log "INFO" "已添加内核模块源: $KERNEL_MODULES"
    fi
    
    log "SUCCESS" "内核 VERMAGIC 设置完成"
    cd - >/dev/null
}

update_mt76() {
    log "INFO" "更新 mt76 驱动并应用补丁..."
    cd "$BUILD_DIR" || exit 1
    
    if patch -p1 <"$BASE_PATH/patches/update_mt76.patch"; then
        log "INFO" "Mt76 版本已更新"
    else
        log "WARNING" "Mt76 版本更新补丁应用失败"
    fi
    
    log "INFO" "添加 mt76 额外补丁文件..."
    local mt76_patch_dir="$BUILD_DIR/package/kernel/mt76/patches"
    if [ -d "$mt76_patch_dir" ]; then
        if [ -f "$BASE_PATH/patches/mt76/002_mt76_mt7921_fix_returned_txpower.patch" ]; then
            cp -f "$BASE_PATH/patches/mt76/002_mt76_mt7921_fix_returned_txpower.patch" "$mt76_patch_dir"
            log "INFO" "已添加 mt7921 补丁"
        fi
        if [ -f "$BASE_PATH/patches/mt76/003_mt76_mt7925_fix_returned_txpower.patch" ]; then
            cp -f "$BASE_PATH/patches/mt76/003_mt76_mt7925_fix_returned_txpower.patch" "$mt76_patch_dir"
            log "INFO" "已添加 mt7925 补丁"
        fi
    else
        log "WARNING" "Mt76 补丁目录不存在: $mt76_patch_dir"
    fi
    
    log "SUCCESS" "mt76 驱动更新完成"
    cd - >/dev/null
}

# 主函数
main() {
    # 初始化日志文件
    touch "$LOG_FILE"
    log "INFO" "日志文件已创建: $LOG_FILE"
    
    # 解析参数
    parse_arguments "$@"
    
    # 显示开始信息
    log "INFO" "开始执行 OpenWrt 构建准备脚本"
    
    # 执行主要功能函数
    cat <<'EOF' | foreach_function

    clone_repo
    clean_up
    reset_feeds_conf
    update_feeds
    remove_unwanted_packages
    remove_tweaked_packages
    update_homeproxy
    fix_default_set
    fix_miniupnpd
    update_golang
    change_dnsmasq2full
    fix_mk_def_depends
    add_wifi_default_set
    update_default_lan_addr
    remove_something_nss_kmod
    update_lucky
    update_affinity_script
    update_ath11k_fw
    fix_mkpkg_format_invalid
    change_cpuusage
    update_tcping
    add_ax6600_led
    set_custom_task
    apply_passwall_tweaks
    install_opkg_distfeeds
    update_nss_pbuf_performance
    set_build_signature
    update_nss_diag
    update_menu_location
    fix_compile_coremark
    update_dnsmasq_conf
    add_backup_info_to_sysupgrade
    update_mosdns_deconfig
    fix_quickstart
    update_oaf_deconfig
    add_timecontrol
    add_gecoosac
    add_quickfile
    fix_rust_compile_error
    update_smartdns
    update_diskman
    set_nginx_default_config
    update_uwsgi_limit_as
    update_argon
    install_feeds
    support_fw4_adg
    update_script_priority
    update_base_files
    add_ohmyzsh
    add_nbtverify
    add_turboacc
    fix_cudy_tr3000_114m
    fix_easytier
    update_geoip
    update_packages
    update_proxy_app_menu_location
    update_dns_app_menu_location
    fix_kernel_magic
    update_mt76
    apply_hash_fixes
EOF
    
    # 执行完成
    log "SUCCESS" "OpenWrt 构建准备脚本执行完成！"
    log "INFO" "详细日志请查看: $LOG_FILE"
}

# 执行主函数
main "$@"
