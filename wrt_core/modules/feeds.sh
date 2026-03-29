#!/usr/bin/env bash

update_feeds() {
    local FEEDS_PATH="$BUILD_DIR/$FEEDS_CONF"
    if [[ -f "$BUILD_DIR/feeds.conf" ]]; then
        FEEDS_PATH="$BUILD_DIR/feeds.conf"
    fi
    sed -i '/^#/d' "$FEEDS_PATH"
    sed -i '/packages_ext/d' "$FEEDS_PATH"

    if ! grep -q "small-package" "$FEEDS_PATH"; then
        [ -z "$(tail -c 1 "$FEEDS_PATH")" ] || echo "" >>"$FEEDS_PATH"
        echo "src-git small8 https://github.com/kenzok8/jell" >>"$FEEDS_PATH"
    fi

    # 不添加passwall源
    # if ! grep -q "openwrt-passwall" "$FEEDS_PATH"; then
    #     [ -z "$(tail -c 1 "$FEEDS_PATH")" ] || echo "" >>"$FEEDS_PATH"
    #     echo "src-git passwall https://github.com/Openwrt-Passwall/openwrt-passwall;main" >>"$FEEDS_PATH"
    # fi

    if ! grep -q "openwrt_bandix" "$BUILD_DIR/$FEEDS_CONF"; then
        [ -z "$(tail -c 1 "$BUILD_DIR/$FEEDS_CONF")" ] || echo "" >>"$BUILD_DIR/$FEEDS_CONF"
        echo 'src-git openwrt_bandix https://github.com/timsaya/openwrt-bandix.git;main' >>"$BUILD_DIR/$FEEDS_CONF"
    fi

    if ! grep -q "luci_app_bandix" "$BUILD_DIR/$FEEDS_CONF"; then
        [ -z "$(tail -c 1 "$BUILD_DIR/$FEEDS_CONF")" ] || echo "" >>"$BUILD_DIR/$FEEDS_CONF"
        echo 'src-git luci_app_bandix https://github.com/timsaya/luci-app-bandix.git;main' >>"$BUILD_DIR/$FEEDS_CONF"
    fi

    if [ ! -f "$BUILD_DIR/include/bpf.mk" ]; then
        touch "$BUILD_DIR/include/bpf.mk"
    fi

    ./scripts/feeds update -a
}

install_feeds() {
    ./scripts/feeds update -i
    # 先移除有问题的luci-app-natmap包
    if [[ -d "$BUILD_DIR/feeds/small8/luci-app-natmap" ]]; then
        \rm -rf "$BUILD_DIR/feeds/small8/luci-app-natmap"
        echo "已移除有问题的 luci-app-natmap 包"
    fi
    # 先移除有问题的webd包
    if [[ -d "$BUILD_DIR/feeds/small8/webd" ]]; then
        \rm -rf "$BUILD_DIR/feeds/small8/webd"
        echo "已移除有问题的 webd 包"
    fi
    for dir in $BUILD_DIR/feeds/*; do
        if [ -d "$dir" ] && [[ ! "$dir" == *.tmp ]] && [[ ! "$dir" == *.index ]] && [[ ! "$dir" == *.targetindex ]]; then
            if [[ $(basename "$dir") == "small8" ]]; then
                install_small8
                install_fullconenat
            else
                ./scripts/feeds install -f -ap $(basename "$dir")
            fi
        fi
    done
}
