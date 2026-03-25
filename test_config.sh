#!/bin/bash

# 测试配置文件读取功能

# 检查yq是否安装
if ! command -v yq &> /dev/null; then
    echo "Error: yq is not installed"
    exit 1
 fi

# 测试配置文件是否存在
if [ -f "release_config.yml" ]; then
    echo "✓ Config file exists"
else
    echo "✗ Config file not found"
    exit 1
 fi

# 测试读取配置
SOURCE_CODE=$(yq e '.release.source_code' release_config.yml)
KERNEL_VERSION=$(yq e '.release.kernel_version' release_config.yml)
WIFI_PASSWORD=$(yq e '.release.wifi_password' release_config.yml)
LAN_ADDRESS=$(yq e '.release.lan_address' release_config.yml)
PLUGINS=$(yq e '.release.plugins[]' release_config.yml)

# 验证配置值
if [ -n "$SOURCE_CODE" ]; then
    echo "✓ Source code URL: $SOURCE_CODE"
else
    echo "✗ Source code URL not found"
    exit 1
 fi

if [ -n "$KERNEL_VERSION" ]; then
    echo "✓ Kernel version: $KERNEL_VERSION"
else
    echo "✗ Kernel version not found"
    exit 1
 fi

if [ -n "$WIFI_PASSWORD" ]; then
    echo "✓ WiFi password: $WIFI_PASSWORD"
else
    echo "✗ WiFi password not found"
    exit 1
 fi

if [ -n "$LAN_ADDRESS" ]; then
    echo "✓ LAN address: $LAN_ADDRESS"
else
    echo "✗ LAN address not found"
    exit 1
 fi

if [ -n "$PLUGINS" ]; then
    echo "✓ Plugins found: $(echo "$PLUGINS" | wc -l) plugins"
else
    echo "✗ Plugins not found"
    exit 1
 fi

echo "\n✓ All tests passed!"
exit 0