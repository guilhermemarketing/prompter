# Prompter: teleprompter grátis para macOS

**Prompter é um teleprompter grátis para macOS que acompanha a sua voz e grava câmera, tela e microfone no mesmo app.** É open-source (MIT), sem assinatura, sem compras dentro do app e sem marca d'água. Feito em Swift para Mac com Apple Silicon (M1, M2, M3, M4 e posteriores), com todo o processamento no próprio computador.

Criado por **[Gui · gui.marketing](https://gui.marketing)**.

*English below: [free teleprompter for Mac](#english).*

## Por que usar o Prompter como teleprompter no Mac

- **100% gratuito de verdade:** nenhum recurso fica atrás de pagamento. Código aberto no GitHub.
- **Segue a sua fala:** o texto rola sozinho enquanto você fala, como um karaokê. Você não precisa ajustar a velocidade nem usar pedal ou controle remoto.
- **Teleprompter e gravador juntos:** grava a câmera, a tela ou as duas, com áudio sincronizado. Você não precisa de OBS nem de outro gravador.
- **Texto perto da câmera:** o roteiro pode ficar fixo no topo da tela, junto da câmera do MacBook ou do iMac, para o seu olhar continuar na lente.
- **Privado:** transcrição, recorte de fundo e sincronia rodam no Mac. Nenhum roteiro ou vídeo é enviado para a internet.

## Recursos do teleprompter

- **Modo voz (karaokê):** transcrição de fala on-device. As palavras já ditas ficam apagadas e a próxima linha sobe sozinha. Tolera improvisos e trechos pulados. O idioma (português, inglês e outros) é detectado pelo roteiro.
- **Modo tempo:** rolagem em velocidade constante, ajustável pelo teclado.
- **Três posições do texto:**
  - sobre a prévia da câmera;
  - em caixa solta sempre à frente das outras janelas;
  - fixo no topo da tela, junto da câmera.
- **Tamanho da fonte e atalhos de teclado** para controlar tudo sem tirar os olhos do texto.

## Gravação de vídeo com teleprompter

- **Câmera:** formatos 16:9 (YouTube), 9:16 (Reels, TikTok, Shorts) e 4:5 (feed), com o recorte já na prévia. Resolução HD, 2K ou 4K, a 24, 30 ou 60 fps, conforme a câmera.
- **Gravação de tela com câmera:**
  - tela inteira, janela ou área desenhada;
  - câmera em destaque em círculo, quadrado ou retângulo, que você arrasta e redimensiona na prévia;
  - você escolhe os arquivos: composição, só a tela e/ou só a câmera, todos sincronizados.
- **Imagem:**
  - luz automática guiada pelo rosto;
  - ajustes de contraste, brilho, pretos, sombras, brancos, nitidez e matiz, com presets;
  - LUTs `.cube` (5 incluídas) com controle de intensidade;
  - fundo chroma key (verde, azul ou vermelho) e estilos cel-shading e adesivo.
- **Qualidade:** Econômica, Recomendada, Superior HEVC, Superior ProRes 422 HQ ou taxa personalizada até 250 Mbps.
- **Áudio:**
  - microfone mono gravado nos dois canais;
  - correção automática da sincronia labial depois de cada gravação, sem recodificar;
  - fila de áudio sem descartes.
- **Cor fiel:** os arquivos saem marcados como sRGB e ficam iguais à prévia.

## Requisitos

- macOS 26 ou posterior.
- Mac com Apple Silicon.
- Command Line Tools do Xcode (`xcode-select --install`). O Xcode completo não é necessário.

## Como instalar

Por enquanto, o app é instalado a partir do código-fonte:

```bash
git clone https://github.com/guilhermemarketing/prompter.git
cd prompter
./build.sh --install
```

O comando compila o app e copia o **Prompter** para `/Applications`. Sem `--install`, o app fica em `dist/Prompter.app`.

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

O app pede acesso à câmera e ao microfone. Para gravar a tela, pede também Gravação de Tela e Áudio do Sistema. Nada sai do Mac: transcrição, segmentação de pessoa e análise de sincronia rodam localmente. Na primeira vez em que o modo voz é usado num idioma, o macOS baixa o modelo de voz da Apple.

Os vídeos ficam em `~/Movies/Prompter/`.

## Atalhos de teclado

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

## Perguntas frequentes

### O Prompter é mesmo um teleprompter grátis para macOS?

Sim. O Prompter é gratuito e open-source, sob licença MIT. Não tem plano pago, assinatura, limite de tempo nem marca d'água nos vídeos.

### Funciona em MacBook e iMac?

Funciona em qualquer Mac com Apple Silicon e macOS 26 ou posterior. Ele usa a câmera embutida ou uma webcam USB, e o microfone embutido ou um externo.

### O teleprompter rola sozinho enquanto eu falo?

Sim, no modo voz. O app reconhece a fala no próprio Mac e avança o roteiro conforme você lê. Se preferir, o modo tempo rola o texto em velocidade fixa.

### Dá para gravar a tela e a câmera ao mesmo tempo?

Sim. O Prompter grava a tela, uma janela ou uma área, com a câmera em destaque. Ele também pode salvar a tela e a câmera em arquivos separados para edição.

### Serve para Reels, TikTok e YouTube?

Sim. Os formatos 9:16, 4:5 e 16:9 já saem recortados, em até 4K.

### Meu roteiro é enviado para algum servidor?

Não. O texto, a voz e os vídeos ficam no seu Mac.

## Arquitetura

- **`CaptureEngine`:** câmera, microfone e captura de tela.
- **`FrameProcessor`:** luz, cor, LUT, máscara de pessoa e chroma, recorte e escala na GPU, com renderização assíncrona.
- **`ScreenCompositor`:** tela mais câmera em destaque.
- **`MovieWriter`:** AVAssetWriter com fila de áudio e preenchimento de lacunas.
- **`SpeechFollower` + `ScriptAligner`:** voz → posição no roteiro.
- **`PrompterLayout` + `PrompterTextView`:** TextKit, karaokê e rolagem a 120 Hz.
- **`LipSync`:** medição e correção da sincronia labial.

`@ViewState` é um alias de `SwiftUI.State` para compilar sem o plugin de macros, que só acompanha o Xcode.

## Licença e autoria

MIT. Veja [LICENSE](LICENSE).

Prompter foi criado por [Gui, do gui.marketing](https://gui.marketing).

---

## English

**Prompter is a free, open-source teleprompter for Mac that follows your voice and records your camera, screen and microphone.** There is no subscription, no in-app purchase and no watermark. It is native Swift for Apple Silicon Macs running macOS 26 or later, and everything runs on-device.

- **Voice-follow teleprompter:** on-device speech recognition scrolls the script as you read, karaoke-style. A constant-speed mode is also available.
- **Flexible placement:** the text can sit over the camera preview, float above other apps, or stay pinned at the top of the screen next to the camera.
- **Camera recording:** 16:9, 9:16 and 4:5 crops with live preview, up to 4K at 60 fps.
- **Screen recording with camera:** record a display, a window or a selected area, with a draggable camera bubble. Composite, screen-only and camera-only files stay in sync.
- **Look:**
  - face-aware auto exposure;
  - color adjustments with presets;
  - `.cube` LUTs (five included);
  - chroma-key backgrounds and cel-shading or sticker styles.
- **Quality and audio:**
  - HEVC or ProRes 422 HQ;
  - dual-mono microphone;
  - automatic lip-sync correction after each recording;
  - drop-free audio pipeline.

**Install:** you need the Xcode Command Line Tools. Clone the repository and run `./build.sh --install`. The *Assinatura estável* section above shows how to create a local signing certificate, so macOS keeps camera, microphone and screen permissions across builds.

The interface is in Brazilian Portuguese.

Created by [Gui · gui.marketing](https://gui.marketing). License: MIT.
