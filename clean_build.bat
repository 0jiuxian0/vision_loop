@echo off
chcp 65001 >nul
echo Cleaning build cache...
echo.

echo [1/3] Stopping Gradle daemon...
call gradlew --stop
echo.

echo [2/3] Cleaning Flutter build...
call flutter clean
echo.

echo [3/3] Removing Kotlin incremental cache...
if exist "build" (
    rmdir /s /q build
    echo Build directory removed.
)
echo.

echo Clean complete!
echo.
echo You can now rebuild with: flutter build apk --release
echo.
pause

