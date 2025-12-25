# 正式发布指南

## 步骤 1: 生成签名密钥（首次发布需要）

在项目根目录下执行以下命令生成签名密钥：

```bash
keytool -genkey -v -keystore android/vision_loop_keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias vision_loop_key
```

**重要提示：**
- 请妥善保管生成的 `vision_loop_keystore.jks` 文件和密码
- 如果丢失，将无法更新应用
- 建议将密钥文件备份到安全的地方

## 步骤 2: 配置签名信息

编辑 `android/key.properties` 文件，填入你的签名信息：

```properties
storePassword=你的密钥库密码
keyPassword=你的密钥密码
keyAlias=vision_loop_key
storeFile=../vision_loop_keystore.jks
```

**注意：** `key.properties` 文件包含敏感信息，不要提交到版本控制系统！

## 步骤 3: 更新应用信息（可选）

### 更新应用名称
编辑 `android/app/src/main/AndroidManifest.xml`，修改 `android:label` 属性：
```xml
android:label="Vision Loop"
```

### 更新版本号
编辑 `pubspec.yaml`，修改 `version` 字段：
```yaml
version: 1.0.0+1  # 格式：版本名+构建号
```

## 步骤 4: 构建发布版本

### 构建 APK（用于直接安装）
```bash
flutter build apk --release
```

生成的 APK 文件位置：`build/app/outputs/flutter-apk/app-release.apk`

### 构建 App Bundle（用于 Google Play 发布）
```bash
flutter build appbundle --release
```

生成的 AAB 文件位置：`build/app/outputs/bundle/release/app-release.aab`

## 步骤 5: 测试发布版本

在发布前，建议在真实设备上测试发布版本：

```bash
flutter install --release
```

## 注意事项

1. **签名安全**：确保 `key.properties` 和 `vision_loop_keystore.jks` 不会被提交到 Git
2. **版本号**：每次发布新版本时，记得更新 `pubspec.yaml` 中的版本号
3. **测试**：发布前务必在多个设备上测试应用功能
4. **权限**：确保所有必要的权限已在 `AndroidManifest.xml` 中声明

## 发布到 Google Play

1. 登录 [Google Play Console](https://play.google.com/console)
2. 创建新应用或选择现有应用
3. 上传 AAB 文件（不是 APK）
4. 填写应用信息、截图等
5. 提交审核

## 发布到其他应用商店

如果发布到其他应用商店（如华为应用市场、小米应用商店等），使用 APK 文件即可。

