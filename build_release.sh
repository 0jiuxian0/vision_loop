#!/bin/bash

echo "========================================"
echo "Vision Loop 发布版本构建脚本"
echo "========================================"
echo ""

# 检查签名文件是否存在
if [ ! -f "android/vision_loop_keystore.jks" ]; then
    echo "[错误] 未找到签名密钥文件！"
    echo ""
    echo "请先执行以下命令生成签名密钥："
    echo "keytool -genkey -v -keystore android/vision_loop_keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias vision_loop_key"
    echo ""
    exit 1
fi

if [ ! -f "android/key.properties" ]; then
    echo "[错误] 未找到签名配置文件 android/key.properties！"
    echo ""
    echo "请先创建并配置 android/key.properties 文件"
    echo ""
    exit 1
fi

echo "[1/3] 清理之前的构建..."
flutter clean
echo ""

echo "[2/3] 获取依赖..."
flutter pub get
echo ""

echo "[3/3] 构建发布版本 APK..."
flutter build apk --release
echo ""

if [ $? -eq 0 ]; then
    echo "========================================"
    echo "构建成功！"
    echo "========================================"
    echo ""
    echo "APK 文件位置："
    echo "build/app/outputs/flutter-apk/app-release.apk"
    echo ""
    echo "如果要构建 App Bundle（用于 Google Play），请执行："
    echo "flutter build appbundle --release"
    echo ""
else
    echo "========================================"
    echo "构建失败！"
    echo "========================================"
    echo ""
fi

