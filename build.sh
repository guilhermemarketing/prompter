#!/bin/zsh
# Compila o Prompter (release, arm64), monta o .app e assina.
# Uso: ./build.sh            → dist/Prompter.app
#      ./build.sh --install  → também copia para /Applications
set -euo pipefail
cd "${0:A:h}"

# Build e montagem fora da pasta do projeto: se ela estiver no iCloud Drive, o iCloud readiciona
# atributos estendidos e o codesign recusa assinar ("resource fork, Finder information... not allowed").
# PROMPTER_SCRATCH escolhe outra pasta de build (ex.: um SSD externo).
SCRATCH="${PROMPTER_SCRATCH:-${TMPDIR:-/tmp}/prompter-build}"
mkdir -p "$SCRATCH"

swift build -c release --arch arm64 --scratch-path "$SCRATCH"
BIN="$(swift build -c release --arch arm64 --scratch-path "$SCRATCH" --show-bin-path)/Prompter"

if [[ ! -f Resources/AppIcon.icns ]]; then
  ICONSET="$SCRATCH/AppIcon.iconset"
  rm -rf "$ICONSET" && mkdir -p "$ICONSET"
  swift Scripts/make-icon.swift "$ICONSET"
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
fi

STAGE="$SCRATCH/stage/Prompter.app"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BIN" "$STAGE/Contents/MacOS/Prompter"
cp Resources/Info.plist "$STAGE/Contents/Info.plist"
cp Resources/AppIcon.icns "$STAGE/Contents/Resources/AppIcon.icns"
# Localizações: o macOS escolhe português ou inglês (os demais idiomas caem no inglês).
for LPROJ in Resources/*.lproj; do cp -R "$LPROJ" "$STAGE/Contents/Resources/"; done
# Sparkle (atualizações), vindo do artefato binário do SwiftPM.
SPARKLE="$(find "$SCRATCH/artifacts" -path "*macos-arm64_x86_64/Sparkle.framework" -maxdepth 6 -type d | head -1)"
mkdir -p "$STAGE/Contents/Frameworks"
ditto "$SPARKLE" "$STAGE/Contents/Frameworks/Sparkle.framework"
xattr -cr "$STAGE"

# Com um certificado de assinatura no Chaves (veja o README), a identidade do app não muda entre
# builds e o macOS mantém as permissões de câmera, microfone e Gravação de Tela. Sem ele, ad-hoc.
IDENTITY="${PROMPTER_SIGNING_IDENTITY:-Prompter Local Signing}"
if security find-identity -p codesigning 2>/dev/null | grep "\"$IDENTITY\"" >/dev/null; then
  SIGN="$IDENTITY"
else
  echo "Aviso: certificado \"$IDENTITY\" ausente; usando assinatura ad-hoc (permissões caem a cada build)."
  SIGN="-"
fi
# O Sparkle é assinado de dentro para fora, com a mesma identidade do app.
FW="$STAGE/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign --force --sign "$SIGN" --timestamp=none -o runtime "$FW/XPCServices/Installer.xpc"
codesign --force --sign "$SIGN" --timestamp=none -o runtime --preserve-metadata=entitlements "$FW/XPCServices/Downloader.xpc"
codesign --force --sign "$SIGN" --timestamp=none -o runtime "$FW/Autoupdate"
codesign --force --sign "$SIGN" --timestamp=none -o runtime "$FW/Updater.app"
codesign --force --sign "$SIGN" --timestamp=none -o runtime "$STAGE/Contents/Frameworks/Sparkle.framework"
codesign --force --sign "$SIGN" --timestamp=none "$STAGE"
codesign --verify --deep --strict "$STAGE"

# Cópia de conveniência no projeto (dentro do iCloud a assinatura pode não validar; instale com --install).
rm -rf dist/Prompter.app
mkdir -p dist
ditto --noextattr "$STAGE" dist/Prompter.app

if [[ "${1:-}" == "--install" ]]; then
  rm -rf "/Applications/Prompter.app"
  ditto --noextattr "$STAGE" /Applications/Prompter.app
  codesign --verify --strict /Applications/Prompter.app
  echo "Instalado em /Applications/Prompter.app"
fi
echo "Pronto: $STAGE"
