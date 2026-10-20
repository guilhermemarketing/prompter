# Prompter

Teleprompter com gravação de câmera, tela e microfone para macOS. Nativo (Swift, SwiftUI, AVFoundation, ScreenCaptureKit, Vision e Speech), sem dependências externas e com todo o processamento no próprio Mac.

*English summary below.*

## Recursos

- **Teleprompter**
  - **Modo voz (karaokê):** o texto acompanha a sua fala com transcrição on-device; as palavras ditas ficam apagadas e a linha seguinte sobe sozinha. Tolera improvisos e trechos pulados. O idioma é detectado pelo roteiro.
  - **Modo tempo:** rolagem em velocidade constante.
  - **Três posições:** sobre a prévia, em caixa solta sempre à frente, ou fixo no topo da tela, junto da câmera do iMac/MacBook.
- **Gravação de câmera:** formatos 16:9, 9:16 e 4:5 com o recorte já na prévia; HD, 2K ou 4K a 24, 30 ou 60 fps (dentro do que a câmera suporta).
- **Gravação de tela:** tela inteira, janela ou área desenhada, com a câmera em destaque (círculo, quadrado ou retângulo neobrutalista) que você arrasta e redimensiona na prévia. Você escolhe os arquivos: composição, só a tela e/ou só a câmera. Eles saem sincronizados.
- **Imagem:**
  - luz automática guiada pelo rosto;
  - ajustes de contraste, brilho, pretos, sombras, brancos, nitidez e matiz, com presets;
  - LUTs `.cube` (5 incluídas) com intensidade;
  - fundo chroma (verde, azul, vermelho) e estilos cel-shading e adesivo.
- **Qualidade:** Econômica, Recomendada, Superior HEVC, Superior ProRes 422 HQ ou taxa personalizada até 250 Mbps.
- **Áudio:**
  - microfone mono gravado nos dois lados;
  - sincronia labial: compensação da latência da câmera e correção automática após cada gravação, por análise boca × voz, sem recodificar;
  - fila de áudio sem descartes.
- **Cor fiel:** os arquivos saem marcados como sRGB e aparecem iguais à prévia.

## Requisitos

- macOS 26 ou posterior, Apple Silicon.
- Command Line Tools do Xcode (`xcode-select --install`). O Xcode completo não é necessário.

## Build

```bash
./build.sh            # gera dist/Prompter.app
./build.sh --install  # e copia para /Applications
```

Variáveis opcionais:

- `PROMPTER_SCRATCH`: pasta de build (padrão: `$TMPDIR/prompter-build`).
- `PROMPTER_SIGNING_IDENTITY`: certificado de assinatura (padrão: `Prompter Local Signing`).

### Assinatura estável (recomendado)

Com assinatura ad-hoc, o macOS pede de novo câmera, microfone e Gravação de Tela a cada build. Para evitar isso, crie uma vez um certificado de assinatura local no seu Chaves:

```bash
cat > /tmp/prompter-cert.cnf <<'EOF'
[ req ]
distinguished_name = dn
prompt = no
x509_extensions = ext
[ dn ]
CN = Prompter Local Signing
[ ext ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
openssl req -x509 -newkey rsa:2048 -nodes -keyout /tmp/k.pem -out /tmp/c.pem -days 3650 -config /tmp/prompter-cert.cnf
openssl pkcs12 -export -inkey /tmp/k.pem -in /tmp/c.pem -name "Prompter Local Signing" -out /tmp/id.p12 -passout pass:temp
security import /tmp/id.p12 -k ~/Library/Keychains/login.keychain-db -P temp -T /usr/bin/codesign
rm -P /tmp/k.pem /tmp/id.p12 /tmp/c.pem /tmp/prompter-cert.cnf
```

## Permissões e privacidade

O app pede câmera, microfone e, para gravar a tela, Gravação de Tela e Áudio do Sistema. Nada sai do Mac: transcrição, segmentação de pessoa e análise de sincronia rodam localmente. Na primeira vez em que o modo voz é usado num idioma, o macOS baixa o modelo de voz da Apple.

Os vídeos ficam em `~/Movies/Prompter/`.

## Atalhos

| Ação | Atalho |
|---|---|
| Ouvir / rolar / pausar | Espaço |
| Modo voz ↔ tempo | V (⇧⌘V) |
| Velocidade (modo tempo) | ↑ ↓ |
| Voltar / avançar um trecho | ← → (ou trackpad) |
| Voltar ao início | ⌘↑ ou Home |
| Texto maior / menor | ⌘= / ⌘− |
| Alternar formato | F |
| Luz automática | L (⇧⌘L) |
| Posição do teleprompter | T |
| Gravar / parar | R (⌘R) |
| Editar roteiro | E (⌘E; Esc fecha) |
| Pasta de gravações | ⇧⌘O |

## Arquitetura

- **`CaptureEngine`:** câmera, microfone e captura de tela.
- **`FrameProcessor`:** luz, cor, LUT, máscara de pessoa e chroma, recorte e escala na GPU, com renderização assíncrona.
- **`ScreenCompositor`:** tela mais câmera em destaque.
- **`MovieWriter`:** AVAssetWriter com fila de áudio e preenchimento de lacunas.
- **`SpeechFollower` + `ScriptAligner`:** voz → posição no roteiro.
- **`PrompterLayout` + `PrompterTextView`:** TextKit, karaokê e rolagem a 120 Hz.
- **`LipSync`:** medição e correção da sincronia labial.

`@ViewState` é um alias de `SwiftUI.State` para compilar sem o plugin de macros, que só acompanha o Xcode.

## Licença

MIT. Veja [LICENSE](LICENSE).

---

## English

**Prompter** is a native macOS teleprompter with camera, screen and microphone recording. It is written in Swift and SwiftUI with Apple frameworks only, and everything runs on-device.

- **Voice-follow karaoke teleprompter:** on-device speech transcription keeps the script in step with your speech. A time-based scroll mode is also available. The text can sit over the preview, in a floating box or pinned under the camera notch.
- **Camera recording:** 16:9, 9:16 and 4:5 crops with live preview; HD, 2K or 4K at 24, 30 or 60 fps.
- **Screen recording:** a display, a window or a selected area, with a draggable neo-brutalist camera bubble. You choose which synced files to record: composite, screen-only and/or camera-only.
- **Look:**
  - face-aware auto exposure;
  - color adjustments with presets;
  - `.cube` LUTs (five included);
  - chroma-key backgrounds and cel-shading or sticker styles.
- **Quality and audio:**
  - HEVC or ProRes 422 HQ;
  - dual-mono microphone;
  - automatic lip-sync correction after every recording;
  - drop-free audio pipeline.

**Build:** macOS 26+ on Apple Silicon with the Xcode Command Line Tools, then run `./build.sh --install`. The *Assinatura estável* section above shows how to create a local signing certificate, so that macOS keeps camera, microphone and screen permissions across builds.

The interface is in Brazilian Portuguese.

License: MIT.
