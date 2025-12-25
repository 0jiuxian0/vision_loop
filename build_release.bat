@echo off
chcp 65001 >nul
echo ========================================
echo Vision Loop Release Build Script
echo ========================================
echo.

REM Check if keystore file exists
if not exist "android\vision_loop_keystore.jks" (
    echo [ERROR] Keystore file not found!
    echo.
    echo Please run the following command to generate keystore:
    echo keytool -genkey -v -keystore android\vision_loop_keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias vision_loop_key
    echo.
    pause
    exit /b 1
)

if not exist "android\key.properties" (
    echo [ERROR] key.properties file not found!
    echo.
    echo Please create and configure android\key.properties file
    echo.
    pause
    exit /b 1
)

echo [1/3] Cleaning previous build...
call flutter clean
echo.

echo [2/3] Getting dependencies...
call flutter pub get
echo.

echo [3/3] Building release APK...
call flutter build apk --release
echo.

if %ERRORLEVEL% EQU 0 (
    echo ========================================
    echo Build successful!
    echo ========================================
    echo.
    echo APK location:
    echo build\app\outputs\flutter-apk\app-release.apk
    echo.
    echo To build App Bundle for Google Play, run:
    echo flutter build appbundle --release
    echo.
) else (
    echo ========================================
    echo Build failed!
    echo ========================================
    echo.
)

pause

