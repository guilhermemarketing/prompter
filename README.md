# Prompter: teleprompter grátis e automático para macOS

<p align="center">
  <img src="docs/teleprompter-automatico-macos.gif" alt="Teleprompter automático para macOS: o texto do Prompter acompanha a voz, palavra por palavra, e espera durante o improviso" width="820">
</p>

<p align="center"><em>Teleprompter automático: você fala e o texto acompanha. Se improvisar, ele espera; quando você volta ao roteiro, ele se localiza.</em></p>

<p align="center">
  <a href="https://github.com/guilhermemarketing/prompter/stargazers"><img src="https://img.shields.io/github/stars/guilhermemarketing/prompter?style=flat&logo=github&label=estrelas" alt="Estrelas no GitHub"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-000000?logo=apple" alt="macOS 26 ou posterior">
  <img src="https://img.shields.io/badge/Apple%20Silicon-M1%2B-555555" alt="Apple Silicon">
  <img src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white" alt="Swift 6">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/guilhermemarketing/prompter?label=licen%C3%A7a" alt="Licença MIT"></a>
  <img src="https://img.shields.io/badge/pre%C3%A7o-gr%C3%A1tis-2ea44f" alt="Grátis">
</p>

**Prompter é um teleprompter grátis para macOS que rola sozinho conforme você fala e grava câmera, tela e microfone no mesmo app.** Dá para gravar Reels, vídeos para o YouTube e aulas direto do Mac, lendo o roteiro sem desviar o olhar da câmera. É open-source (MIT), sem assinatura, sem compras dentro do app e sem marca d'água. Feito em Swift para Mac com Apple Silicon (M1, M2, M3, M4 e posteriores), com todo o processamento no próprio computador.

Criado por **[Gui · gui.marketing](https://gui.marketing)**. Se o Prompter te ajudou, deixe uma ⭐ no repositório: isso ajuda outras pessoas a encontrá-lo.

*English below: [free teleprompter for Mac](#english).*

## Teleprompter automático: o texto segue a sua voz

O modo voz é o coração do Prompter. Em vez de rolar numa velocidade fixa que você precisa acompanhar, o teleprompter automático ouve a sua fala e avança o texto no seu ritmo:

- **Palavra por palavra:** o que você já falou fica apagado e a linha seguinte sobe sozinha até a altura da câmera.
- **Improviso sem perder o lugar:** se você sai do roteiro, o texto espera. Quando você volta, ele encontra o trecho e continua.
- **Trechos pulados:** se você pula uma frase ou um parágrafo, ele se reencontra mais adiante.
- **Sem controle remoto, pedal ou ajuste de velocidade:** você só fala. Se quiser reposicionar, role no trackpad.
- **No próprio Mac:** o reconhecimento de voz roda on-device, em português, inglês, espanhol, francês, italiano ou alemão, conforme o idioma do roteiro.

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

## Gravar Reels no Mac com teleprompter

Escolha o formato 9:16 e grave Reels, TikTok e Shorts direto do Mac, já recortados na vertical, em até 4K. O roteiro fica junto da câmera e rola sozinho enquanto você fala, então o vídeo sai com você olhando para a lente, sem decorar o texto e sem celular. Os formatos 4:5 (feed) e 16:9 (YouTube) funcionam do mesmo jeito.

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

### O que é um teleprompter?

Teleprompter é um aparelho ou programa que mostra o texto que você vai falar perto da câmera, rolando conforme a leitura. Ele permite gravar vídeos, aulas, apresentações e lives lendo o roteiro sem desviar o olhar da lente e sem decorar o texto. No computador, o teleprompter é um app que exibe o roteiro na tela, de preferência logo abaixo da webcam.

### O que é um teleprompter automático?

É um teleprompter que rola o texto sozinho, acompanhando a voz de quem fala, em vez de usar velocidade fixa ou um operador. No Prompter, o reconhecimento de fala identifica a palavra em que você está e leva essa linha para perto da câmera. Assim você pode pausar, acelerar ou improvisar sem perder o lugar.

### Existe teleprompter grátis para Mac?

Sim. O Prompter é um teleprompter grátis para Mac, open-source sob licença MIT. Muitos apps de teleprompter para macOS aparecem como gratuitos na App Store, mas cobram assinatura ou compras dentro do app para liberar recursos. No Prompter não há plano pago, limite de tempo nem marca d'água: tudo, inclusive a gravação em 4K e a rolagem por voz, é gratuito.

### Como usar teleprompter no Mac?

1. Instale o Prompter (veja [Como instalar](#como-instalar)) e permita o acesso à câmera e ao microfone.
2. Cole o seu roteiro no editor (tecla E).
3. Escolha onde o texto aparece (tecla T). Fixo no topo, junto da câmera, é a posição que mais mantém o olhar na lente.
4. Ative o modo voz (tecla V) para o texto acompanhar a sua fala, ou use o modo tempo para rolagem constante.
5. Escolha o formato (16:9, 9:16 ou 4:5) e grave com R. O vídeo vai para `~/Movies/Prompter/`.

### Qual a diferença entre o Prompter e outros teleprompters para Mac?

O Prompter junta três coisas que costumam exigir apps separados: teleprompter que segue a voz, gravação da câmera e gravação da tela com a câmera em destaque. Ele também corrige a sincronia entre boca e voz depois de cada gravação. Por ser open-source, qualquer pessoa pode conferir o código, sugerir melhorias ou adaptar o app.

### O teleprompter precisa de internet?

Não. O reconhecimento de voz roda no próprio Mac. A internet só é usada uma vez, quando o macOS baixa o modelo de voz da Apple para o idioma do roteiro.

### Funciona em MacBook e iMac?

Funciona em qualquer Mac com Apple Silicon e macOS 26 ou posterior. Ele usa a câmera embutida ou uma webcam USB, e o microfone embutido ou um externo.

### O teleprompter rola sozinho enquanto eu falo?

Sim, no modo voz. O app reconhece a fala no próprio Mac e avança o roteiro conforme você lê. Se preferir, o modo tempo rola o texto em velocidade fixa.

### Dá para gravar a tela e a câmera ao mesmo tempo?

Sim. O Prompter grava a tela, uma janela ou uma área, com a câmera em destaque. Ele também pode salvar a tela e a câmera em arquivos separados para edição.

### Dá para gravar Reels direto do Mac?

Sim. No formato 9:16, o Prompter grava o vídeo vertical já recortado para Reels, TikTok e Shorts, em até 4K, com o teleprompter automático na tela. Para o feed, use 4:5; para o YouTube, 16:9.

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
- **`DemoRenderer`:** gera a animação deste README com o mesmo código do app (`--demo-render ROTEIRO VOZ PASTA`).

`@ViewState` é um alias de `SwiftUI.State` para compilar sem o plugin de macros, que só acompanha o Xcode.

## Licença e autoria

MIT. Veja [LICENSE](LICENSE).

Prompter foi criado por [Gui, do gui.marketing](https://gui.marketing).

---

## English

**Prompter is a free, open-source automatic teleprompter for Mac: it follows your voice and records your camera, screen and microphone.** You can record Reels, YouTube videos and classes straight from your Mac. There is no subscription, no in-app purchase and no watermark. It is native Swift for Apple Silicon Macs running macOS 26 or later, and everything runs on-device.

- **Automatic, voice-follow teleprompter:** on-device speech recognition scrolls the script as you read, karaoke-style. If you improvise, it waits; when you return to the script, it finds its place. A constant-speed mode is also available.
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

**Is there a free teleprompter for Mac?** Yes. Prompter is completely free and open-source (MIT). It has no paid tier, time limit or watermark, and 4K recording and voice scrolling are included.

**What is a teleprompter?** A teleprompter shows your script near the camera and scrolls it as you read. You can record videos, classes and presentations while keeping your eyes on the lens.

**Install:** you need the Xcode Command Line Tools. Clone the repository and run `./build.sh --install`. The *Assinatura estável* section above shows how to create a local signing certificate, so macOS keeps camera, microphone and screen permissions across builds.

The interface is in Brazilian Portuguese.

Created by [Gui · gui.marketing](https://gui.marketing). If Prompter helps you, please ⭐ the repository. License: MIT.
