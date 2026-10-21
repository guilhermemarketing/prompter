#!/bin/zsh
# Publica uma versão do Prompter: build, zip, assinatura EdDSA do Sparkle, appcast.xml e Release no GitHub.
# A versão vem de Resources/Info.plist (CFBundleShortVersionString e CFBundleVersion, que precisa subir a cada versão).
#
# Uso: SPARKLE_BIN=/caminho/Sparkle/bin Scripts/release.sh notas.md
#   notas.md: notas da versão em Markdown (viram o texto da Release e a descrição no aviso de atualização).
#   SPARKLE_BIN: pasta bin da Release oficial do Sparkle (https://github.com/sparkle-project/Sparkle/releases).
#   A chave privada EdDSA fica no Chaves, na conta "marketing.gui.prompter" (generate_keys --account).
set -euo pipefail
cd "${0:A:h}/.."

NOTES="${1:?informe o arquivo de notas em Markdown}"
SPARKLE_BIN="${SPARKLE_BIN:?informe SPARKLE_BIN (pasta bin do Sparkle, com sign_update)}"
REPO="${PROMPTER_REPO:-guilhermemarketing/prompter}"
KEY_ACCOUNT="${SPARKLE_KEY_ACCOUNT:-marketing.gui.prompter}"
SCRATCH="${PROMPTER_SCRATCH:-${TMPDIR:-/tmp}/prompter-build}"

plist() { /usr/libexec/PlistBuddy -c "Print $1" Resources/Info.plist; }
VERSION="$(plist CFBundleShortVersionString)"
BUILD="$(plist CFBundleVersion)"
MINOS="$(plist LSMinimumSystemVersion)"
TAG="v$VERSION"; [[ "$VERSION" == *.*.* ]] || TAG="v$VERSION.0"

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "A Release $TAG já existe. Suba CFBundleShortVersionString e CFBundleVersion em Resources/Info.plist." >&2
  exit 1
fi

PROMPTER_SCRATCH="$SCRATCH" ./build.sh
OUT="$SCRATCH/release-$VERSION"
rm -rf "$OUT" && mkdir -p "$OUT"
ditto -c -k --sequesterRsrc --keepParent "$SCRATCH/stage/Prompter.app" "$OUT/Prompter.zip"

# sparkle:edSignature="…" length="…"
SIGNATURE="$("$SPARKLE_BIN/sign_update" --account "$KEY_ACCOUNT" "$OUT/Prompter.zip")"
SHA="$(shasum -a 256 "$OUT/Prompter.zip" | cut -d' ' -f1)"

# Notas: Markdown na Release; HTML simples (parágrafos e listas) no aviso do Sparkle.
DESCRIPTION="$(python3 - "$NOTES" <<'PY'
import html, re, sys
out, in_list = [], False
for line in open(sys.argv[1], encoding="utf-8").read().splitlines():
    text = html.escape(line.strip())
    text = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", text)
    text = re.sub(r"`(.+?)`", r"<code>\1</code>", text)
    text = re.sub(r"\[(.+?)\]\((https?://[^)]+)\)", r'<a href="\2">\1</a>', text)
    if line.lstrip().startswith(("- ", "* ")):
        if not in_list: out.append("<ul>"); in_list = True
        out.append(f"<li>{text[2:]}</li>")
        continue
    if in_list: out.append("</ul>"); in_list = False
    if text.startswith("#"): out.append(f"<h3>{text.lstrip('#').strip()}</h3>")
    elif text: out.append(f"<p>{text}</p>")
if in_list: out.append("</ul>")
print("\n".join(out))
PY
)"

cat > "$OUT/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Prompter</title>
    <link>https://github.com/$REPO</link>
    <item>
      <title>Prompter $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MINOS</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/$REPO/releases/tag/$TAG</sparkle:fullReleaseNotesLink>
      <description><![CDATA[
$DESCRIPTION
      ]]></description>
      <enclosure url="https://github.com/$REPO/releases/download/$TAG/Prompter.zip" $SIGNATURE type="application/octet-stream"/>
    </item>
  </channel>
</rss>
EOF

{ cat "$NOTES"; printf '\n\nSHA-256 (Prompter.zip): `%s`\n' "$SHA"; } > "$OUT/notes.md"
# A Release mais recente serve o appcast.xml do feed (SUFeedURL aponta para releases/latest/download/appcast.xml).
gh release create "$TAG" "$OUT/Prompter.zip" "$OUT/appcast.xml" --repo "$REPO" --target main \
  --title "Prompter $VERSION" --notes-file "$OUT/notes.md" --latest
echo "Publicado: https://github.com/$REPO/releases/tag/$TAG"
