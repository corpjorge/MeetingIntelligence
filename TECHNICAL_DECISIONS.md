# Decisiones técnicas

Formato: contexto → decisión → consecuencias. Todo lo marcado como "comprobado" se verificó en este entorno
(MacBook Pro M5 Pro, 24 GB, macOS 27.0.1, Command Line Tools con Swift 6.4, sin Xcode).

## TD-01 · SwiftPM + Command Line Tools (sin proyecto Xcode)
Xcode no está instalado (`xcodebuild` no disponible). La app se compila con SwiftPM y `scripts/build-app.sh` arma el
bundle (`Info.plist`, icono generado con Core Graphics + `iconutil`, firma). Pruebas con **Swift Testing**
(XCTest no se incluye en CLT). Consecuencia: no hay `#Preview`, asset catalogs ni Instruments; los colores se definen
en código (`DS.Color`).

## TD-02 · SDK macOS 26.5 con solo CLT (comprobado)
En el SDK de macOS 27, `@State`/`@Entry` de SwiftUI son **macros** de `SwiftUIMacros`, cuyo plugin solo viene con
Xcode; con CLT la compilación falla (`plugin for module 'SwiftUIMacros' not found`). `scripts/swiftw` selecciona el SDK
26.5 incluido en CLT cuando no hay Xcode. El mismo código compila con Xcode y el SDK 27.

## TD-03 · Plugin de macros de Swift Testing con solo CLT (causa raíz comprobada)
Síntoma intermitente: `plugin for module 'TestingMacros' not found`. Comparando compilaciones con `-v`, en las que
fallan el sistema de compilación omite `-external-plugin-path …/host/plugins/testing` para el target de pruebas.
`scripts/test.sh` pasa siempre `-Xswiftc -plugin-path <CLT>/usr/lib/swift/host/plugins/testing` cuando no hay Xcode;
verificado con 3 ejecuciones consecutivas tras modificar las pruebas (55/55, sin fallos).

## TD-04 · Core Audio Process Taps para Teams
Comparado con ScreenCaptureKit: los taps (macOS 14.2+) permiten limitar la captura a **procesos concretos**, no
requieren permiso de grabación de pantalla (solo "Grabación de audio del sistema") y entregan host time por buffer.
- Teams usa procesos `com.microsoft.teams2*` y **helpers WebView2** (`com.microsoft.edgewebview2.helper*`) dentro de
  `Microsoft Teams.app` (comprobado con `pgrep`/Info.plist). Se seleccionan por bundle ID **o por ruta del ejecutable**
  dentro del bundle de Teams, para no capturar el WebView2 de Outlook.
- Si Teams aún no es cliente de audio, la pista remota espera y se rellena con silencio para mantener sincronía.
- "Todo el sistema" es una elección explícita del usuario y se indica en UI y metadatos (`captureScope`).
- Aggregate device solo con el tap (sin dispositivo de salida como subdispositivo) para no mezclar el micrófono de
  auriculares Bluetooth en la pista remota; `tapautostart = false` (patrón comprobado en producción por Muesli).

## TD-05 · WAV 16 kHz mono a prueba de cierres
Formato que consumen Parakeet y la diarización (sin re-conversión). Cabecera actualizada y `fsync` cada 2 s; tras un
cierre inesperado se pierden ≤ 2 s y `WAVRepair` reconstruye la cabecera. ≈ 115 MB por hora y pista.

## TD-06 · Sincronización por host time
`TimelineAligner` compara la posición esperada (host time − origen − pausas) con las muestras escritas: rellena
huecos > 40 ms y descarta adelantos > 40 ms (deriva). Ambas pistas empiezan en el mismo origen
(`timelineOffsetSeconds = 0`).

## TD-07 · Parakeet Ultra sin sustitución silenciosa
`AsrModels.downloadAndLoad(version: .ultra)` (FluidAudio 0.17.7, versión fijada). Si falla, se informa el error; nunca
se usa v3/v2 en su lugar. Configuración idéntica a la CLI oficial (`TdtConfig(blankId: 8192)`). La pista de idioma
`es` de FluidAudio solo filtra por **alfabeto** (latino), así que el inglés técnico no se bloquea (comprobado en el
código fuente). Modelos cargados una vez por proceso y reutilizados (también por la transcripción en vivo).

## TD-08 · Transcripción provisional en vivo
FluidAudio ofrece `SlidingWindowAsrManager` compatible con modelos v3/Ultra (ventanas 2+11+2 s, hipótesis cada 1 s,
texto *volátil* vs *confirmado*). Se usa con los **mismos modelos ya cargados** (FluidAudio ya comparte instancias de
modelo entre workers concurrentes en su ruta por lotes). El texto en vivo es solo provisional y nunca se guarda como
transcripción; la definitiva es la pasada offline completa.

## TD-09 · Diarización offline VBx con `stepRatio = 0.1`
Ventanas de segmentación más densas recuperan turnos cortos ("sí", "ok") según FluidAudio #879. Configurable en
Ajustes. Las intervenciones superpuestas se conservan y se marcan como `uncertain` (≥ 30 % de solapamiento).

## TD-10 · Reconocimiento de participantes sin umbrales arbitrarios
`SpeakerManager` de FluidAudio solo es compatible con el pipeline en streaming (documentado), así que el
reconocimiento usa los embeddings WeSpeaker **del mismo pipeline offline** para enrolamiento y reuniones.
- Calibración derivada de los datos: umbral = máxima similitud impostora observada (0 falsos aceptados en
  calibración); margen requerido = desviación estándar de las similitudes genuinas.
- Sin datos suficientes (≥ 2 personas con ≥ 2 muestras) **nunca** se asigna automáticamente; solo sugerencias
  filtradas por mejor-coincidencia-mutua dentro de la reunión.
- < 3 s de voz → solo sugerencia. Decisiones auditables en `speakerAssignment`.

## TD-11 · Una tabla de hallazgos con evidencia
`analysisItem` (categoría + naturaleza + evidencia) cubre las 16 categorías pedidas sin multiplicar tablas;
`Decision`, `ActionItem`, `MeetingTopic` son alias tipados. La evidencia se **re-verifica localmente**: si la cita no
aparece en la transcripción → "Información no confirmada".

## TD-12 · Seguridad de los proveedores de IA (formatos comprobados)
- Claude Code: `claude -p --output-format json --json-schema … --tools "" --strict-mcp-config --no-session-persistence
  --permission-mode dontAsk --system-prompt …`; la salida estructurada llega en `structured_output` (documentación
  oficial). En este entorno el CLI devolvió `OAuth session expired`, así que la ruta de éxito no se ejecutó aquí.
- Codex: `codex exec --sandbox read-only --ephemeral --output-schema … -o … -C <dir vacío>` (ejecución real exitosa).
- Antigravity: `agy -p … --output-format json --json-schema … --sandbox`; en headless las herramientas se deniegan
  automáticamente. Comprobado: sin instrucción explícita intentó ejecutar un comando y devolvió vacío; con instrucción
  de no usar herramientas respondió, pero con **dos** objetos JSON en `response` → `JSONExtraction` elige el que tiene
  las claves esperadas. Nunca se usa `--dangerously-skip-permissions`.
- Ollama: solo endpoints loopback; JSON schema vía `format`.
- Siempre: directorio temporal vacío, timeout, cancelación (SIGTERM→SIGKILL), consentimiento previo para proveedores
  en la nube con el resumen exacto de lo que se comparte, transcripción delimitada como datos no confiables.

## TD-13 · MCP propio, dual-era
La especificación vigente (2026-07-28) es sin sesión (`_meta` por solicitud, `server/discover` obligatorio); muchos
clientes aún usan `initialize` (2025-11-25). Se implementa JSON-RPC propio (sin dependencias) que atiende ambas eras.
Acceso deshabilitado por defecto (`mcp-access.json`), solo lectura, validación estricta de parámetros, límite de 20
llamadas/s.

## TD-14 · Cifrado
Embeddings biométricos sellados con AES-GCM (CryptoKit), clave de 256 bits en el Llavero de inicio de sesión
(`AfterFirstUnlockThisDeviceOnly`). Transcripciones: protección en reposo de FileVault, permisos 0700/0600 y
`secure_delete`. (No se usa SQLCipher para no reemplazar el SQLite del sistema.)

## TD-15 · Verificación visual sin permisos de pantalla
`screencapture` está bloqueado para este proceso (sin permiso de Grabación de pantalla, que no se modifica).
`SnapshotDriver` (activo solo con `MI_SNAPSHOT_DIR`) recorre las pantallas y renderiza la ventana con
`cacheDisplay`. Limitación comprobada: el material de la barra lateral no se renderiza fuera de pantalla; su
contenido se verifica estructuralmente (6 filas presentes en el `NSOutlineView`).

## TD-16 · Identidades manuales al re-procesar
Re-procesar reemplaza los clusters de diarización. Antes de reemplazarlos se capturan las identidades **manuales**
vigentes (no las automáticas, que el reconocimiento recalcula) con los tramos de voz de cada hablante. Un cluster
nuevo hereda una identidad solo con **mayoría mutua**: ≥ 50 % de su voz cae dentro de los tramos de ese participante
(sin empate con otro) **y** el cluster nuevo se queda con más del 50 % de la voz de al menos un hablante previo con esa
identidad. Así el mapeo es uno a uno por hablante previo: un fragmento minoritario nunca hereda el nombre, porque
puede ser otra persona que el cluster antiguo había absorbido; una división a partes iguales deja ambas partes como
desconocidas. Prioridad: fiabilidad sobre comodidad (mejor "desconocido" que un nombre equivocado); el fragmento sin
nombre aún puede identificarse por reconocimiento calibrado o a mano. Hablantes previos con el mismo nombre (cluster
dividido que el usuario ya unificó) conservan el nombre en sus clusters nuevos. Cada re-aplicación queda auditada en
`speakerAssignment` ("Re-aplicada tras reprocesar"). Verificado con los modelos reales.
Las filas `merge`/`split` (contabilidad al fusionar o deshacer una fusión) no ocultan el origen manual: se ignoran al
decidir si la identidad vigente es manual.

## TD-17 · Cualquier app de videollamada, sin lista cerrada
La fuente remota es una **app arbitraria**: sus procesos se agrupan por el `.app` más externo que contiene cada
ejecutable (patrón comprobado con Teams/WebView2, Zoom/CptHost, Chrome y Edge). El catálogo
(`ConversationAppCatalog`) solo aporta nombre, tipo y nivel de aislamiento; una app desconocida se puede grabar igual.
Navegadores y Safari reproducen desde procesos compartidos (servicio de audio de Chromium, `com.apple.WebKit.GPU`):
se graba todo lo que suene en ellos y la UI lo advierte. Safari se mapea al grupo WebKit GPU.

## TD-18 · Detección de llamadas por Core Audio, solo sugerencias
Señal: la misma app con `kAudioProcessPropertyIsRunningInput` **y** `…IsRunningOutput` durante ≥ 3 s. Fin: micrófono
liberado ≥ 25 s (los cambios a AirPods lo liberan brevemente) o app cerrada. No requiere permisos. No se usan títulos
de ventana (exigirían Grabación de pantalla) ni Accessibility. Nunca se inicia ni se detiene una grabación
automáticamente (requisito M); las notificaciones de macOS son opcionales.

## TD-19 · "Pausar mi micrófono" sin manejador de silencio del sistema
`AVAudioApplication.setInputMuteStateChangeHandler` es para "el proceso que hace la E/S de audio de la llamada"
(documentación del SDK); registrarlo podría quitarle a Teams/Zoom el gesto de silencio de los AirPods. La pausa es
un control propio: se escribe silencio en la pista del micrófono y se registra el intervalo.

## TD-20 · Esfuerzo de razonamiento por proveedor (comprobado)
- Claude Code: `--effort low|medium|high|xhigh|max` (`claude --help`, v2.1.286).
- Codex: `-c model_reasoning_effort="…"` (clave verificada en el binario 0.160.1 y en `~/.codex/config.toml`);
  los niveles admitidos dependen del modelo y Codex los informa si no corresponde.
- Antigravity: `--effort low|medium|high|max` (`agy --help`).
- Ollama: `think` con los valores que cada modelo declara en `/api/show` (`thinking.values`); sin valores, no se ofrece.
El esfuerzo usado queda registrado en cada análisis (`aiAnalysis.effort`).

## TD-21 · Diarización sin voz suficiente no es un fallo
FluidAudio lanza `OfflineDiarizationError.noSpeechDetected` cuando no puede extraer ninguna huella de voz, aunque
Parakeet sí transcriba palabras (respuestas de 1–2 s). Pasó en una llamada real de Teams y dejaba la
reunión en error. Ahora `DiarizationService` lo trata como resultado vacío (`speechDetected == false`):
- se conserva la transcripción;
- en el micrófono, el fragmento se atribuye al usuario local (no se detectaron varios hablantes locales);
- en otras pistas, los segmentos quedan sin atribuir.

El resto de errores de diarización sigue siendo fatal. Los mensajes de FluidAudio se muestran en español
(`ProcessingErrorText`). La regresión se prueba con el fixture `es_short_reply`.

## TD-22 · Frases cortas en otro idioma: compactar el silencio muerto antes del ASR
Caso real (llamada de Teams): la pista remota empezó con "(saludo con la primera palabra en francés)" (se dijo "Aló") y el micrófono
(≈ 1–2 s de voz) salió como "(frase en inglés)".

**Diagnóstico** (FluidAudio 0.17.7, código leído en `.build/checkouts/FluidAudio`):
- `language:` solo filtra tokens por **alfabeto** (`TokenLanguageFilter`: latino, cirílico o griego). Ultra usa el
  decodificador v3 (`TdtDecoderV3`) y no tiene prompt ni token de idioma. Español, inglés, francés, portugués,
  alemán e italiano usan el mismo alfabeto, así que `es-CO` → `.spanish` no puede impedir la deriva. Medido: la salida
  con `nil` y con `.spanish` es idéntica en 167 de 169 audios; en los otros 2, un resultado en cirílico pasó a
  `<unk>`. La lista de bloqueo de palabras inglesas de FluidAudio solo se aplica al francés.
- **El nivel no es la causa**: frases sintéticas a −40 dBFS aciertan igual o más que a −20 dBFS (26/40 frente a 25/40
  con silencio largo; 32/40 frente a 29/40 aisladas). Normalizar el micrófono real (`dynaudnorm`, `speechnorm`,
  ganancia + limitador) da el mismo inglés o texto vacío. No se normaliza el nivel.
- **La causa es la falta de contexto dentro de la ventana de ~15 s**. FluidAudio documenta que una ventana que termina
  en silencio muerto se decodifica de forma degenerada (`Documentation/ASR/LongTranscription.md`). La pista remota
  tenía 12,7 s de silencio muerto (−75 dBFS) y "Aló" quedó al final de la primera ventana: el mismo audio desplazado
  3 s, o recortado, da "Aló". La pista del micrófono era silencio digital (pausas) salvo 4,7 s.

**Corrección**: `SilenceCompactor` (MeetingAudio) colapsa los tramos de ≥ 1 s de silencio muerto, es decir, tramas de
80 ms con RMS < 0,0005 (−66 dBFS, el mismo umbral `speechRmsFloor` que usa FluidAudio, por debajo de cualquier voz real),
y deja 240 ms a cada lado del sonido. `ParakeetUltraProvider` decodifica una copia temporal compactada con la API
pública `transcribe(_:decoderState:language:)`. La copia se escribe por bloques (memoria constante), en el formato de
origen (las muestras conservadas llegan intactas), y se borra al terminar. Las marcas de tiempo se devuelven en la línea
de tiempo original, y un token nunca se estira sobre un hueco eliminado. Si no hay nada que compactar se usa el archivo
original sin tocar (resultado idéntico al anterior). No cambia el modelo, el idioma ni el audio guardado; la
diarización sigue leyendo el archivo original.

| Conjunto (verificación local) | Antes | Después |
|---|---|---|
| 24 diálogos sintéticos (frases cortas entre silencios; una al final de la 1.ª ventana) | WER 10,7 %, 14/24 exactos | WER 1,9 %, 22/24 |
| 80 frases aisladas en 22 s de silencio (4 voces × 10 frases × 2 niveles) | WER 26,6 %, 51/80 | WER 20,1 %, 62/80 |
| Fixtures previos (`es_*`, `silence`) | — | mismo texto (solo `es_short_reply` y `silence` tienen silencio muerto) |
| Reunión real, pista remota | "(saludo con la primera palabra en francés)…" | "Aló, ¿cómo está?…"; se pierde el "No," de "(respuesta corta)" (confianza 0,52) |
| Reunión real, micrófono | "(frase en inglés)" | "(palabra en español)" (confianza 0,71; sin referencia, no se puede afirmar que sea correcto) |

**Lo que no resuelve** (documentado, sin solución con la API actual):
- Una frase muy corta, aislada y sin contexto puede seguir saliendo en otro idioma: después de compactar, 18 de 80
  siguen sin coincidir (p. ej. "¿Ya está?" → "Wie er ist da?" o "Надежда.", "Listo." → "Visto?",
  "No, todavía no." → "No, to Gabriano."). Es una propiedad del modelo multilingüe y no hay API para forzar el idioma.
- Con `language: .spanish`, un resultado en otro alfabeto puede llegar como `<unk>` en vez de cirílico.
- Marcar segmentos de baja confianza solo detecta una parte: con confianza media < 0,7 se marcan 24 de 59 errores
  (y 4 de 196 aciertos); "(francés)" tenía 0,87–0,98. La transcripción marca esos fragmentos con "revisar" y la
  leyenda los cuenta (`TranscriptSegment.isLowConfidence`; la marca desaparece al editar el texto). Una frase sin marca
  no está garantizada como correcta.
- Solo se compacta por debajo de −66 dBFS: el ruido de fondo de un micrófono abierto no se toca.
- Mientras se transcribe hay una copia temporal del audio en el `$TMPDIR` del usuario (directorio 0700).

## TD-23 · El silencio de la app de la llamada no se puede leer (comprobado)
Silenciarte en Teams/Zoom no detiene la pista del micrófono: la captura es propia (AVAudioEngine) y no depende del
silencio de la llamada. Se buscó una señal pública para avisar "estás silenciado en X, pero se graba". No la hay:
- **SDK** (cabeceras de macOS 26.5 y 27): `AVAudioApplication.isInputMuted` / `inputMuteStateChangeNotification`
  ("per-application input muting"), `kAudioHardwarePropertyProcessInputMute` y `kAudioDevicePropertyProcessMute`
  describen el silencio **del propio proceso**. Los objetos de proceso del HAL (`kAudioProcessProperty*`) solo exponen
  PID, bundle ID, dispositivos e `IsRunning`/`IsRunningInput`/`IsRunningOutput`.
- **Prueba real** (16-oct-2026, macOS 27.0.1, Teams 26261.303.5165.1465, Galaxy Buds Pro): sonda con un
  `AVAudioEngine` de entrada activo, como la app, muestreando cada 200 ms durante ~5 min mientras el usuario
  silenciaba y reactivaba Teams 3 veces (~10 s cada vez, hablando). No cambiaron `isInputMuted`, la notificación
  (0 recibidas), `ProcessInputMute`, `ProcessMute` ni `kAudioDevicePropertyMute`/`VolumeScalar` de entrada. El proceso
  `com.microsoft.teams2.modulehost` mantuvo `IsRunningInput = 1` todo el tiempo: Teams sigue capturando el micrófono
  estando silenciado. Hubo un único corte de 126 ms que no se repitió en los otros cambios, así que no indica el
  estado. El micrófono propio nunca entregó silencio (picos de voz de hasta −10 dBFS).
- **API de Teams para apps de terceros** (la de Stream Deck): Microsoft documenta la función, pero no el protocolo.
  Según su artículo "Connect to third-party devices in Microsoft Teams", se activa en Configuración › Privacidad ›
  Administrar API › Habilitar API. Depende de una política global del administrador de TI, y el emparejamiento se
  dispara pulsando un botón del dispositivo durante una reunión, es decir, **enviando una orden**. El binario
  instalado contiene el módulo (`third_party_devices`, servidor WebSocket en 127.0.0.1, `protocol-version`,
  `meetingUpdate`, `meetingState`, `isMuted`, `canPair`, `tokenRefresh`, `query-state`, `pairingStatus`). En la cuenta
  de prueba, que es de una organización, la página Privacidad no muestra el apartado y la búsqueda de "API" o
  "terceros" en Configuración no encuentra nada. Una sonda pasiva, que no envía nada, reintentó cada 2 s durante
  318 s y Teams nunca abrió el puerto 8124. Conclusión: aquí no se puede activar ni verificar, así que no se
  implementa un cliente con un protocolo no comprobado. Si TI la habilitara, faltaría además comprobar que
  `isMuted` llega sin enviar órdenes: Microsoft indica que el emparejamiento se dispara con una orden del
  dispositivo, y eso choca con el requisito de solo lectura. Tampoco serviría para Zoom ni Meet.
- **Descartado**: `setInputMuteStateChangeHandler` (TD-19); leer el botón de Teams con Accessibility (permiso
  intrusivo y frágil, TD-18); atajos de teclado sintéticos hacia Teams.

Decisión: un recordatorio **estático** en la vista de grabación (`CallMuteReminder`) cuando se graba el micrófono junto
con una app o todo el sistema. Su botón solo **pausa** (`pauseMicrophone()`, que nunca reanuda) y se puede ocultar
durante esa grabación. Nada se pausa ni se reanuda solo. Zoom no se probó (no había llamada activa).

## Limitaciones comprobadas
- ASR monocanal pierde palabras en habla **superpuesta** (fixture: 2 de 16 palabras).
- Frases muy cortas y aisladas pueden transcribirse en otro idioma; el idioma no se puede forzar (TD-22).
- Los fixtures son TTS: WER/DER medidos son una cota optimista.
- Bluetooth en llamadas usa perfil de banda estrecha (se advierte en UI).
- Apps en navegador: no se puede aislar una pestaña; se graba todo el audio del navegador.
- Silenciarte en la app de la llamada no pausa tu micrófono aquí, y la app no puede detectarlo (TD-23).
