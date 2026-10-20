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
xattr -cr "$STAGE"

# Com um certificado de assinatura no Chaves (veja o README), a identidade do app não muda entre
# builds e o macOS mantém as permissões de câmera, microfone e Gravação de Tela. Sem ele, ad-hoc.
IDENTITY="${PROMPTER_SIGNING_IDENTITY:-Prompter Local Signing}"
if security find-identity -p codesigning 2>/dev/null | grep "\"$IDENTITY\"" >/dev/null; then
  codesign --force --sign "$IDENTITY" --timestamp=none "$STAGE"
else
  echo "Aviso: certificado \"$IDENTITY\" ausente; usando assinatura ad-hoc (permissões caem a cada build)."
  codesign --force --sign - --timestamp=none "$STAGE"
fi
codesign --verify --strict "$STAGE"

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
