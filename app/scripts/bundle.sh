#!/bin/sh
# Сборка приложения: release-бинарь, иконка, Info.plist, шрифты (ATSApplicationFontsPath), ad-hoc подпись.
#   scripts/bundle.sh        → build/AgentTeam.app        сборка владельца (иконка со знаком команды)
#   scripts/bundle.sh --dev  → build/AgentTeamDev.app     проверочная сборка разработчика: имя «AgentTeam Dev»,
#                                                          другой bundle id (свои настройки), серая иконка с меткой DEV
# Проверочные запуски и --snapshot идут только из dev-варианта: окна сборки владельца и проверочной не спутать.
set -eu
APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$APP_DIR"

VARIANT=owner
for a in "$@"; do
    case "$a" in
        --dev) VARIANT=dev ;;
        *) echo "bundle.sh: неизвестный параметр $a" >&2; exit 2 ;;
    esac
done
if [ "$VARIANT" = dev ]; then
    BUNDLE_DIR=AgentTeamDev.app; EXE=AgentTeamDev; NAME="AgentTeam Dev"; DISPLAY_NAME="AgentTeam Dev"; BUNDLE_ID=dev.agent-team.app.dev
else
    BUNDLE_DIR=AgentTeam.app; EXE=AgentTeam; NAME=AgentTeam; DISPLAY_NAME="agent-team"; BUNDLE_ID=dev.agent-team.app
fi

swift build -c release --product AgentTeamApp
BIN="$(swift build -c release --show-bin-path)/AgentTeamApp"
OUT="$APP_DIR/build/$BUNDLE_DIR"
rm -rf "${OUT:?}"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources/Fonts"
cp "$BIN" "$OUT/Contents/MacOS/$EXE"
cp Resources/Fonts/*.ttf Resources/Fonts/*.txt "$OUT/Contents/Resources/Fonts/"

# Иконка: рисуется кодом, затем iconutil собирает .icns (без сети и внешних файлов).
ICONSET="$(mktemp -d)/AppIcon.iconset"
swift scripts/make-icon.swift "$VARIANT" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$OUT/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "${ICONSET:?}")"

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$EXE</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>ATSApplicationFontsPath</key><string>Fonts</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
codesign -s - --force --deep "$OUT" >/dev/null 2>&1 || true
echo "$OUT"
