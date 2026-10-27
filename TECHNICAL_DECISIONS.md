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
- Codex: `codex exec --ignore-user-config --ignore-rules --sandbox read-only --ephemeral -c web_search="disabled"
  --disable shell_tool --disable unified_exec [--disable …] --output-schema … -o … -C <dir vacío>`. Comprobado con
  Codex 0.160.1 (22-oct-2026) con una sonda inocua (un token aleatorio en un archivo temporal):
  - **Antes** solo se pedía en el prompt no usar herramientas. Codex ejecutó `cat`, devolvió el token y listó
    `exec_command`, `spawn_agent` y el MCP de Azure DevOps del usuario. Además cargaba `~/.codex/config.toml`
    entero: servidores MCP, plugins, hooks, `notify`, `web_search = "live"` (el `sandbox_mode` lo sobrescribía
    `--sandbox`). Una transcripción con instrucciones maliciosas podía leer archivos del Mac y enviarlos a la nube.
  - **Ahora** `--ignore-user-config` no carga ese archivo (la sesión sigue en `CODEX_HOME`) y sin `shell_tool` ni
    `unified_exec` no hay forma de ejecutar comandos: ni directamente ni con un subagente (`spawn_agent` falla con
    `code-mode host is disabled`). El token no apareció en ninguna salida.
  - `--disable` con un nombre desconocido hace fallar Codex (`Unknown feature flag`), así que la lista se cruza con
    `codex features list` (en caché por ejecutable). Si esa versión no lista `shell_tool` y `unified_exec`, **no se
    envía nada** y se pide actualizar Codex. Las demás funciones (apps, plugins, navegador, computer use, imágenes,
    multiagente, hooks…) se desactivan solo si existen.
  - Modelo y esfuerzo vacíos siguen siendo los de `config.toml`: solo se leen `model` y `model_reasoning_effort`
    (cadenas de primer nivel con caracteres seguros) y se pasan con `-m`/`-c`. Un `model_provider` distinto de
    `openai` no se usa y se avisa en Ajustes.
  - Análisis real con un fixture sintético: correcto, con el modelo de `config.toml` y las citas verificadas.
- Antigravity: `agy -p … --output-format json --json-schema … --sandbox`; en headless las herramientas se deniegan
  automáticamente. Comprobado: sin instrucción explícita intentó ejecutar un comando y devolvió vacío; con instrucción
  de no usar herramientas respondió, pero con **dos** objetos JSON en `response` → `JSONExtraction` elige el que tiene
  las claves esperadas. Nunca se usa `--dangerously-skip-permissions`.
- GitHub Copilot CLI (`copilot`, 1.0.101): `copilot --output-format json --no-auto-update --no-custom-instructions
  --no-ask-user --disable-builtin-mcps --disallow-temp-dir --no-remote-export --disable-client-telemetry
  --available-tools=mi_sin_herramientas --deny-tool=shell --deny-tool=write --deny-tool=url`. El prompt va por stdin
  y se ejecuta con un `COPILOT_HOME` temporal, aislado de la configuración personal. Comprobado el 22-oct-2026:
  - **`--available-tools=` vacío no desactiva nada.** El modelo seguía viendo `bash`, `view`, `web_fetch` y
    subagentes, y usó una herramienta. Con un nombre inexistente en la lista, Copilot oculta todas («Disabled tools:
    bash, create, edit, glob, grep…»). Control con un archivo inocuo en el directorio de trabajo: sin restricciones
    lo leyó con `view`; con ellas respondió «SIN HERRAMIENTAS» y no hubo ningún `tool.execution_start`. Si apareciera
    alguno, la respuesta se descarta.
  - **`COPILOT_HOME` temporal:** no carga *hooks* (que ejecutan comandos), plugins, servidores MCP, instrucciones ni
    carpetas de confianza del usuario. La sesión, el registro y los logs (que contienen la transcripción) se crean
    ahí y se borran al terminar. La autenticación sigue funcionando porque Copilot la toma del llavero o de `gh`. Se
    quitan `COPILOT_ALLOW_ALL`, `COPILOT_ASSISTED_APPROVAL` y `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` del entorno.
    Corrección de cuentas independientes (27-oct-2026, CLI 1.0.104): se replica solo la identidad seleccionada
    (`lastLoggedInUser`, entrada correspondiente de `loggedInUsers`: host/login/kind) para que la CLI consulte
    su propio Llavero. No se copian credenciales, hooks, plugins, instrucciones ni carpetas de confianza. Se lee
    el estado JSON5 sin modificarlo. Con una cuenta de Copilot seleccionada se retiran los tokens genéricos de
    GitHub del entorno del hijo; la sesión global de `gh` no se cambia. Un `COPILOT_GITHUB_TOKEN` explícito
    conserva su prioridad. No se fuerza `gh auth token` ni `--no-auto-login`. Antes del catálogo y del envío
    de texto se verifica `auth.getStatus`: una cuenta distinta o fallback a gh produce error. La interfaz
    muestra el usuario verificado. Prueba real sin inferencia: cuenta empresarial con 20 modelos + Automático,
    mientras `gh` conserva la personal. Adaptador del estado interno comprobado en esta versión; si no se puede
    leer o verificar la cuenta se informa del fallo.
  - No tiene `--json-schema`: el esquema va en el prompt y `JSONExtraction` toma el objeto con las claves esperadas
    del último `assistant.message` del JSONL, que también indica el modelo usado. Los errores solo usan stderr,
    porque el JSONL repite el prompt, es decir, la transcripción.
  - El catálogo de modelos depende del plan: con la cuenta personal de prueba solo «auto» estaba disponible
    (`--model X` → «is not available»). Modelo vacío = «auto».
  - Otra herramienta también se llama `copilot` (AWS Copilot CLI): solo se usa si `--version` dice «GitHub Copilot».
  - Regresión de configuración (27-oct-2026): la interfaz permitía guardar modelo automático + esfuerzo medio;
    el proveedor rechazaba la combinación antes del envío. La app normaliza esa preferencia a esfuerzo
    predeterminado al leer y guardar, y desactiva el selector con modelo automático. El esfuerzo explícito se
    conserva con modelos concretos. El error del análisis ahora se muestra también en Decisiones y Compromisos.
    Pruebas de controlador con la configuración heredada y consentimiento; prueba real con texto sintético,
    modelo automático y herramientas desactivadas (`MI_COPILOT_TEST=1`, `CopilotCLIIntegrationTests`).
  - Selector de modelos en la barra de análisis: usa los modelos detectados de cada proveedor y conserva la
    elección por proveedor. Copilot consulta `connect` → `models.list` mediante el protocolo SDK del CLI
    (`--headless --stdio`, mensajes con `Content-Length`), sin crear sesión ni enviar un prompt. La autenticación
    existente se mantiene solo en el entorno del subproceso, dentro de un `COPILOT_HOME` temporal. Tiempo límite
    de 20 s y respuestas acotadas. No se requiere instalar el SDK. Fuente del protocolo:
    https://github.com/github/copilot-sdk/blob/main/nodejs/src/client.ts.
    En la cuenta personal de prueba el catálogo devuelve `models: []` aunque está autenticada. La CLI interactiva confirma
    que la sesión `corpjorge` (plan Student) ofrece únicamente Automático. No se proponen modelos usados en
    análisis previos: un modelo elegido automáticamente no acredita selección manual. Un catálogo cargado prevalece
    sobre una preferencia anterior que ya no figura en él; al fallar la consulta se conserva el modelo guardado.
    No se ofrecen modelos de imagen ni se inventan IDs. Cambiar de modelo restaura el esfuerzo predeterminado.
  - Codex consulta `app-server` → `initialize` → `initialized` → `model/list` (JSONL), con paginación y sin crear
    hilos ni turnos. Se desactivan comandos, plugins y hooks y se consulta el proveedor OpenAI que utiliza el
    análisis. El app-server no admite `--ignore-user-config` (ese flag pertenece a `exec`); la ruta de análisis
    mantiene su aislamiento anterior. Prueba real: ocho modelos visibles, sin inferencia. Se filtran modelos
    ocultos y modalidades que no aceptan texto. El catálogo puede ser local/cacheado y no acredita acceso a cada
    modelo hasta una inferencia exitosa. Fuente: https://developers.openai.com/codex/app-server.
  - Textos de análisis seleccionables y botones de copia por resumen, elemento y sección; las citas se pueden
    seleccionar sin activar reproducción. El timestamp sigue siendo el botón para escuchar la evidencia.
  - Sin sesión termina con «No authentication information found» antes de enviar nada → «Sin sesión».
  - Análisis real y chat sobre el fixture sintético: correctos (modelo `gpt-5.6-luna`, 8,3 s, citas verificadas).
    Cada ejecución cuenta como una solicitud de Copilot.
- Ollama: solo endpoints loopback; JSON schema vía `format`.
- Siempre: directorio temporal vacío, timeout, cancelación (SIGTERM→SIGKILL), consentimiento previo para proveedores
  en la nube con el resumen exacto de lo que se comparte, transcripción delimitada como datos no confiables.
- La transcripción va por stdin. Si la CLI termina sin leerla entera (sesión caducada, flag no reconocido), escribir
  en la tubería cerrada enviaba SIGPIPE y **cerraba la app**, también en plena grabación (comprobado: código 141).
  El extremo de escritura se marca con `F_SETNOSIGPIPE`, así que la escritura falla con EPIPE y la app sigue.

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
- GitHub Copilot CLI: `--reasoning-effort minimal|low|medium|high|xhigh|max` (`copilot --help`, 1.0.101). Con el
  modelo «auto» lo rechaza («does not support reasoning effort configuration»), así que la app exige un modelo
  concreto antes de enviar nada.
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
Caso real (llamada de Teams autorizada; no se citan sus palabras): un saludo corto en español de la pista remota salió
con su primera palabra en francés, y una respuesta de 1–2 s del micrófono salió como una frase en inglés.

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
| Reunión real, pista remota | saludo con la primera palabra en francés | saludo en español; se pierde la primera palabra de una respuesta posterior (confianza 0,52) |
| Reunión real, micrófono | frase en inglés | una palabra en español (confianza 0,71; sin referencia, no se puede afirmar que sea correcta) |

**Lo que no resuelve** (documentado, sin solución con la API actual):
- Una frase muy corta, aislada y sin contexto puede seguir saliendo en otro idioma: después de compactar, 18 de 80
  siguen sin coincidir (p. ej. "¿Ya está?" → "Wie er ist da?" o "Надежда.", "Listo." → "Visto?",
  "No, todavía no." → "No, to Gabriano."). Es una propiedad del modelo multilingüe y no hay API para forzar el idioma.
  Seguimiento en TD-26: con voz cercana de la misma pista como contexto se corrige la mayoría.
- Con `language: .spanish`, un resultado en otro alfabeto puede llegar como `<unk>` en vez de cirílico.
- Marcar segmentos de baja confianza solo detecta una parte: con confianza media < 0,7 se marcan 24 de 59 errores
  (y 4 de 196 aciertos); el saludo en francés de la reunión real tenía 0,87–0,98. La transcripción marca esos fragmentos con "revisar" y la
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

## TD-24 · Refuerzo acústico del diccionario con Parakeet CTC 110M (medido)
FluidAudio 0.17.7 no aplica vocabulario dentro de `AsrManager` (la documentación muestra
`transcribe(_:customVocabulary:)`, que no existe en esta versión). Lo público es
`VocabularyBoostingSession.rescore(text:tokenTimings:audioSamples:)`: un modelo CTC aparte (Parakeet CTC 110M,
~98 MB, entrenado en inglés) compara el audio con cada término y reemplaza palabras del texto de Ultra.

**Medición** (voces sintéticas `say`, 3 voces × 16 frases con nombres/marcas/términos + 8 de control por voz,
diccionario de 16 términos; `VocabularyBoostExperiment`, se activa con `MI_BOOST_DATA`):

| | Sin refuerzo | Rescoring de FluidAudio tal cual | Con la salvaguarda (pipeline real) |
|---|---|---|---|
| Términos acertados | 17/48 (archivos sueltos) · 20/48 (pipeline) | 41/48 | **39/48** |
| Frases de control cambiadas | — | 3/24 ("Mañana" → "Grafana") | **0/24** |
| Palabras comunes dañadas | — | "firma" → "Figma" (4 casos) | **0** |
| WER total | 13,2 % · 8,1 % | 9,3 % | **4,4 %** |

El CTC inglés puntúa mal cualquier palabra española (−10 a −12 frente a −3 a −6 del término), así que la confianza de
Ultra y la puntuación acústica no separan aciertos de errores. **Salvaguarda**: nunca se reemplaza **una** palabra
que pertenece al idioma de la reunión (lista de 42.337 palabras de `NLEmbedding.wordEmbedding(for: .spanish)`, sin
nombres propios). Los reemplazos de varias palabras se aceptan ("Si Amara" → "Xiomara", "David Vienda" →
"Davivienda"). Costo: términos parecidos a palabras comunes no se corrigen ("gira" → "Jira", "firma" → "Figma").

**Diccionario pequeño** (22-oct-2026, demo de 3 reuniones con 7 términos: Katty, Jonathan, Mónica, Nequi…). El rescoring
reemplazó frases enteras de palabras comunes: "Yo me encargo de documentar los campos…" → "Yo Mónica Mónica Katty
Katty Grafana", "¿Algo más?" → "¿Bancolombia?". Además borraba vecinos de un término ya correcto ("Jonathan,
¿puedes" → "Jonathan"). Se añadieron dos reglas:
- Similitud ortográfica de al menos 0,5 entre el original y el término. Los aciertos medidos están entre 0,60 y 1,00
  y estos errores entre 0,00 y 0,36.
- No se reemplaza un tramo que ya contiene el término.

Resultado: en la demo queda solo "Neki" → "Nequi" (antes 7 cambios, 6 erróneos). En el conjunto de 3 voces sigue igual:
39/48, sin términos insertados de más, WER 4,4 %.

**Integración**: opcional (Ajustes › Transcripción › Diccionario; `mi process --boost-vocabulary`), descarga el modelo
la primera vez. Se ejecuta por segmento sobre su propio audio; el resultado va a `vocabularyText` (con el diccionario
determinista encima) y `asrText` no cambia. Si algo falla, el procesamiento sigue sin refuerzo. Limitación: dentro de
un segmento se reemplaza la primera aparición del texto original; no está medido con voces reales.

## TD-25 · Búsqueda semántica local con multilingual-e5-small (medido)
Los embeddings que trae macOS no sirven en español: con 12 fragmentos y 9 preguntas, `NLEmbedding.sentenceEmbedding`
acertó 3/9 en primer lugar y `NLContextualEmbedding` (media de tokens) 2/9. Se eligió `intfloat/multilingual-e5-small`
(MIT, 384 dimensiones, ~470 MB) con `swift-embeddings` 0.1.1 (MLTensor). Dependencias nuevas: swift-transformers,
swift-huggingface, swift-safetensors, swift-sentencepiece (**binario precompilado** `sentencepiece.xcframework`
publicado por su autor en GitHub), swift-numerics, swift-argument-parser, Command, swift-crypto y yyjson.
`swift-collections` se fija en 1.2.1: 1.7.3 no compila con CLT 27 + SDK 26.5.

**Medición** (30 fragmentos sintéticos tipo reunión, 16 preguntas: 7 comparten palabras con la respuesta, 9 son
paráfrasis):

| | Respuesta entre los 3 primeros | En 1.ª posición |
|---|---|---|
| Palabras (emulación de FTS5) | 5/16 (paráfrasis 2/9) | 5/16 |
| e5-small | **14/16** (paráfrasis 7/9) | 11/16 |
| Fusión RRF (pesos 1–3) | 13/16 | 8/16 |
| De punta a punta (audio TTS → Ultra → índice → `mi ask`) | FTS5 5/16 · **semántica 13/16** | — |

Fallan "problemas de conexión" ("se me cayó el internet"), "¿qué se decidió sobre el presupuesto?" y "riesgos de
seguridad". Las similitudes están comprimidas (0,75–0,9): las preguntas fuera de tema llegan a 0,79–0,82 y la respuesta
correcta más débil quedó en 0,80, así que el umbral (`semanticFloor = 0,80`) no separa del todo y una pregunta fuera de
tema puede traer algún extracto.

**Diseño**: `MeetingSemantic` (módulo nuevo; el servidor MCP no lo enlaza) carga el modelo y calcula vectores;
`segmentEmbedding` (migración v4) guarda un vector por segmento con el hash de su texto, así una edición se reindexa;
borrar una reunión borra sus vectores. La búsqueda es por coseno, por fuerza bruta. En el chat van primero 2/3 de
resultados semánticos, luego los de FTS5 que falten (los nombres exactos no se pierden) y después el resto. Opcional
(Ajustes › Modelos), desactivado por defecto; el modelo se descarga de Hugging Face y el texto nunca sale del equipo.
Rendimiento (M5 Pro, release): carga 3 s, 46 textos en 0,5 s.

## TD-26 · Frases cortas aisladas: redecodificar con contexto y no estirar palabras sobre huecos (medido)
Seguimiento de TD-22. Ultra no acepta un idioma, pero su codificador usa el contexto. `ShortUtteranceContext`
redecodifica cada frase corta y aislada (≤ 3 s, ≤ 6 palabras, ≥ 2 s de silencio a cada lado) precedida de hasta 8 s de
voz de la misma pista, y se queda solo con los tokens de la frase. La nueva versión se usa solo si no está vacía y su
confianza media es igual o mayor.

| 80 frases cortas (4 voces × 10 × 2 niveles) y 20 en inglés | Exactas |
|---|---|
| Cada frase sola en su archivo, sin contexto | español 53/80 · inglés 20/20 |
| Redecodificar siempre con contexto en español | español 73/80 · **inglés 10/20** (se "españolizan") |
| Regla de confianza (la implementada) | **español 74/80 · inglés 19/20** (el restante: "Ok" por "Okay") |

En una pista de micrófono realista (una frase normal + las 20 frases cortas separadas por 15 s de silencio, 4 voces)
apareció otro fallo: con la compactación, el decodificador deja a veces "▁¿" al final del tramo anterior o "." después
del hueco, y la palabra se estiraba 17 s y pegaba dos frases en un segmento (4 casos por pista; TD-22 no lo detectó).
`reattachSplitWords` mueve esa pieza sin letras junto a su palabra.

| Pistas realistas, 80 frases | Exactas |
|---|---|
| Antes | 67/76 comparables (4 pares de frases pegados) |
| Solo el arreglo de piezas | 72/80 |
| Arreglo + redecodificación con contexto | **74/80** |

Los 6 errores restantes no son de idioma ("Allí" por "Ahí", "Togamía", "Un momento…" cortado). Costo: ~0,1 s por
frase corta (pista de 390 s con 20 frases: ASR de 0,6 s a 2,5 s). Una pista con una sola frase no tiene contexto
propio. `asrText` guarda la decodificación elegida. Mediciones: `LanguageDriftExperiment` (`MI_LANG_DATA`).

**Contexto remoto para respuestas sin otra voz local (27-oct-2026).** El pipeline pasa al micrófono el audio y los
tokens de las pistas remotas de esa misma reunión. Si no hay contexto en la pista propia y la confianza original
es < 0,7, se buscan hasta 8 s de voz remota a no más de 30 s de distancia, priorizando la anterior. Los offsets de
ambas pistas se aplican al seleccionar el contexto; solo se guardan los tokens de la respuesta, en su tiempo local.
No se usa voz simultánea ni otra reunión. Se mantiene la condición de confianza igual o mayor. Las respuestas de
hasta 6 s / 16 palabras con confianza < 0,7 también se reintentan: una decodificación errónea puede expandir una
frase breve por encima del límite anterior de seis palabras.

La separación temporal entre contexto y respuesta necesita margen: cortar a 150 ms del inicio perdía la primera
pieza de algunas palabras. Ahora se corta en el punto medio del silencio de 900 ms entre ambas partes (450 ms
antes de la respuesta). Los tiempos anteriores al inicio de la porción original se limitan a ese inicio.

Medición local con 24 audios sintéticos (4 voces × 4 frases en español y 2 en inglés), con otra voz en español como
contexto: español exacto **13/16 → 15/16**; ningún acierto español se dañó. Los 5/8 aciertos ingleses conservaron su
significado; uno cambió «Okay» por «Ok» (coincidencia literal 5/8 → 4/8). Persisten una respuesta sin tokens y tres
«Thanks» mal reconocidos por voces españolas. No es un bloqueo del idioma ni garantiza resolver grabaciones reales.
Regresión reproducible: `es_context_reply` («¿Ya está?», voz Mónica), `PipelineIntegrationTests` y
`ShortUtteranceContextTests`. Medición opcional: `CrossTrackContextExperiment` con `MI_CROSS_TRACK_DATA` apuntando
a un directorio de pares `.wav`/`.txt` sintéticos; escribe `report.txt` en ese directorio.

## TD-27 · Actualizar modelos desde la app y borrar los que no se usan (comprobado)
FluidAudio 0.17.7 descarga Parakeet Ultra y CTC 110M desde la rama `main` de Hugging Face. Una vez en caché, no vuelve
a mirar si hay cambios. La diarización está fijada al commit `df2625a`. swift-embeddings descarga e5-small una vez.

**Detección.** Se compara contra la API pública de Hugging Face (`/api/models/<repo>/revision/main` y
`/tree/<sha>?recursive=true`). Solo se consulta al pulsar «Buscar actualizaciones» y no se envía nada de las
reuniones. Los archivos locales coinciden byte a byte con los publicados: SHA-256 en los archivos LFS y hash de blob
git en el resto. Calcular el del codificador de Ultra (594 MB) tarda alrededor de 1 s. Cada biblioteca baja solo una
parte del repositorio, así que cuenta un archivo remoto solo si existe en local o si pertenece a un paquete Core ML
(`.mlmodelc`/`.mlpackage`) presente en local. Así no aparecen como faltantes las variantes, los ONNX ni los README.
Una primera versión contaba la carpeta `onnx/` entera de e5 y pedía 829 MB. El commit verificado se guarda en
`.mi-revision`. No se toca `.fluidaudio-revision`: FluidAudio daría por obsoleta una caché de `main` con esa marca.
Los modelos fijados por la biblioteca no se actualizan desde la app.

**Actualización.** `ModelInstaller` sigue estos pasos:
1. Copia la carpeta (en APFS es un clon) a `.<modelo>.mi-staging`.
2. Borra ahí los obsoletos y descarga solo los archivos cambiados de ese commit, verificando tamaño y hash.
3. Mueve la versión actual a `.<modelo>.mi-backup` y pone la nueva en su lugar.
4. La carga como lo hará el procesamiento: si carga, borra el respaldo; si no, restaura la anterior.

Un cierre a mitad se deshace al arrancar. No se puede actualizar mientras se graba o se procesa.

**Obsoletos.** Se borran los archivos que ya no existen en la revisión, pero solo dentro de entradas que el
repositorio sigue publicando. Un archivo suelto que no publica podría ser de la biblioteca y no se toca. Además se
listan los modelos sin uso: CTC con el refuerzo apagado, e5 con la búsqueda semántica apagada y las carpetas de la
caché compartida de FluidAudio que esta app no usa. Se borran solo con confirmación, porque otra app con FluidAudio
podría usarlas.

**Verificado.** Contra Hugging Face real: Ultra (95eaa59) y CTC 110M (accdafd) al día, diarización fijada. Sobre una
copia de CTC 110M con un archivo de la raíz alterado, otro dentro de un paquete alterado y un sobrante, se detectó,
se descargaron 2 archivos (< 1 MB), se eliminó el sobrante y el modelo cargó. Sobre una copia de e5 con `config.json`
alterado, la app mostró «1 archivo(s), 655 bytes» y `mi models update` lo restauró idéntico al publicado. Ultra carga
con la marca nueva sin volver a descargar. El botón «Actualizar» de la app no se pulsó en esta verificación: el flujo
se probó con la CLI y con pruebas, que usan el mismo `ModelInstaller`.

## TD-28 · Borrar una reunión libera todo su espacio (comprobado)
Antes ya se borraban en cascada las filas de la reunión y su carpeta de audio. Faltaba lo siguiente, y se añadió:
- **Archivo de SQLite.** Con `auto_vacuum = 0`, las páginas borradas quedan libres dentro del archivo, que nunca se
  encoge (`secure_delete` las sobrescribe, pero no las devuelve). Después de borrar, `compactStorage()` ejecuta
  `VACUUM` y trunca el WAL, en segundo plano. En la prueba, el archivo queda por debajo de la mitad.
- **Muestras de voz.** Las tomadas de la reunión se conservaban en el perfil del participante (`meetingId` pasa a
  NULL). La confirmación ofrece borrarlas también y, por defecto, se conservan. El centroide se calcula al vuelo, así
  que el perfil no necesita recalcularse.
- **Confirmación única** para la lista y el detalle: muestra el tamaño que se libera y cuántos mensajes del chat se
  borran, cancela el procesamiento de esa reunión y muestra los errores (antes se ignoraban con `try?`).
- **Al arrancar:** se borran las carpetas `Recordings/<id>` sin reunión y los temporales propios (`mi-asr-*`,
  `mi-ai-*`, `mi-enroll-*`) de más de 1 h.

No se borra lo que el usuario exportó: son archivos suyos, en una carpeta que él eligió.

## TD-29 · Actualizaciones desde la app (comprobado)
**Detección.** Se consulta `GET https://api.github.com/repos/corpjorge/MeetingIntelligence/releases`. No se usa
`/releases/latest` porque excluye los *pre-releases*, y la 0.1.0 lo es (comprobado: devuelve 404).
- La consulta se hace al abrir la app (si la última tiene más de 1 h) y luego cada 24 h. Se puede desactivar en
  Ajustes › General, donde también está «Buscar ahora»; el menú de la app tiene «Buscar actualizaciones…».
- Solo cuentan los releases que no son borrador, cuyo tag es una versión y que publican `<nombre>-<versión>.zip` y
  `….zip.sig`.
- Si hay una versión más nueva aparece un aviso flotante con «Ver novedades» y «Actualizar». Nunca abre ventanas ni
  descarga nada por sí solo. «Omitir esta versión» la silencia; una búsqueda manual la vuelve a ofrecer.

**Autenticidad.** Cada ZIP se firma con Ed25519 (CryptoKit). El mensaje firmado contiene el contexto, la versión y el
SHA-256 del ZIP. Incluir la versión impide ofrecer un ZIP antiguo y firmado como si fuera nuevo.
- La clave privada se crea una vez con `mi-release keygen` en el Llavero de inicio de sesión. Se guarda y se lee con
  `/usr/bin/security`, así que no aparece en los argumentos de ningún proceso y recompilar no provoca avisos del
  Llavero.
- La clave pública va en `config/app.env` y de ahí a `MIUpdatePublicKey` en el Info.plist. Quien consiga publicar en
  el repositorio pero no tenga la clave privada no puede instalar nada. `SHA256SUMS.txt` no bastaría: lo publica el
  mismo origen que el ZIP.
- Antes de instalar se comprueba además el tamaño publicado, el bundle ID, que `CFBundleShortVersionString` coincida
  con el tag, `LSMinimumSystemVersion` y la firma de código (`SecStaticCodeCheckValidity` estricta, con el código
  anidado). Si algo falla se borra la descarga y no se toca la app.

**Instalación.** Solo se instala al pulsar «Reiniciar e instalar», y nunca mientras se graba, se procesa o se
actualiza un modelo.
1. La app verificada se copia junto a la instalada, en `.<app>.mi-update` (mismo volumen).
2. Las dos se intercambian con un solo `renamex_np(RENAME_SWAP)` atómico, así que en ningún momento falta la app. Si
   el volumen no lo admite, se usan dos renombrados que se deshacen si el segundo falla. El proceso en marcha sigue
   funcionando porque sus archivos siguen abiertos.
3. Un ayudante (`/bin/sh` lanzado con `posix_spawn`, en su propia sesión y sin descriptores heredados) espera a que la
   app termine y la vuelve a abrir. Conserva `MEETING_INTELLIGENCE_HOME` si estaba definido.
4. Al arrancar, la versión nueva borra la anterior y las descargas, y muestra «Se actualizó a la versión X» (o avisa
   de que no se completó).

No se instala si la app se ejecuta desde App Translocation, desde el DMG (volumen de solo lectura) o desde una carpeta
sin permiso de escritura. En esos casos se explica el motivo y se ofrece la descarga desde GitHub.

**Gatekeeper y permisos.**
- Lo que descarga la app no lleva atributo de cuarentena, porque la app no declara `LSFileQuarantineEnabled`
  (comprobado: 0 atributos después de actualizar). Por eso la versión nueva abre sin el paso «Abrir de todos modos».
  La app no quita ninguna cuarentena.
- Con firma ad hoc la identidad cambia en cada compilación, así que macOS vuelve a pedir los permisos de micrófono y
  de audio del sistema. La hoja de actualización lo avisa (la firma ad hoc se detecta con
  `SecCodeCopySigningInformation`). Una identidad de firma estable lo evitaría; está pendiente en el ROADMAP.

**Verificado (22-oct-2026).**
- Pruebas automáticas: versiones, lectura de releases, firma, preparación válida y manipulada (otra clave, versión o
  app distinta, macOS mínimo, tamaño), intercambio y limpieza, ubicaciones donde no se puede instalar, y el controlador
  (aviso, omitir, fallos silenciosos, bloqueo mientras se graba, reinicio).
- De punta a punta con la app real compilada en release: una 0.2.0 en una carpeta temporal y un servidor local
  (`MI_UPDATE_API`) que publicaba una 0.2.1 firmada con la clave real. Con `MI_UPDATE_E2E=1`, la app acepta como lo
  haría el usuario; esto solo funciona con una API loopback. La app detectó, descargó, verificó, reemplazó, se cerró y
  arrancó la 0.2.1 en aproximadamente 1 s. La 0.2.1 registró «installed» y borró la anterior. La firma de código era válida, no
  había cuarentena y siguió usando la misma biblioteca temporal.
- Con una 0.2.2 de firma alterada: la detectó, la rechazó y no cambió nada.
- El aviso y la hoja se verificaron con capturas en modo claro y oscuro.

**Primera actualización real (23-oct-2026), 0.2.0 → 0.2.1 en `/Applications` desde la hoja.** El reemplazo funcionó
(macOS no lo bloqueó), pero la app se quedó en «Instalando y reiniciando…». AppKit ignora `NSApp.terminate` mientras
hay una hoja adjunta, y la prueba de punta a punta instalaba sin la hoja abierta. Desde la 0.2.2 se cierran las hojas
antes de salir (comprobado con una hoja SwiftUI mínima: sin el cambio el proceso sigue vivo; con él termina en
~0,3 s). La 0.2.1 todavía tiene el fallo: al actualizar desde ella hay que usar «Reiniciar e instalar» del aviso, sin
abrir la hoja, o cerrar y abrir la app a mano (la versión nueva ya queda instalada).

**No verificado.** Reemplazar en `/Applications` una copia aprobada con «Abrir de todos modos»: en este Mac la app no
está instalada ahí. La protección de macOS «Gestión de apps» podría pedir permiso. Se comprobará con la primera
actualización real después de la 0.2.0. La 0.1.0 no tiene actualizador, así que la 0.2.0 se instala a mano.

**La clave.** Si se pierde la clave privada, las versiones futuras no se podrán instalar desde la app (sí a mano). Haz
una copia: `security find-generic-password -s dev.meetingintelligence.update-signing -a ed25519 -w`. Para cambiarla
hay que publicar una versión, firmada con la clave antigua, que ya traiga la nueva clave pública.

## Limitaciones comprobadas
- ASR monocanal pierde palabras en habla **superpuesta** (fixture: 2 de 16 palabras).
- Frases muy cortas y aisladas pueden transcribirse en otro idioma; el idioma no se puede forzar. La
  redecodificación con contexto corrige la mayoría si la pista tiene otra voz (TD-22, TD-26).
- El refuerzo acústico del diccionario no corrige términos parecidos a palabras comunes ("Jira"/"gira", TD-24).
- La búsqueda semántica falla en algunas paráfrasis y puede traer algún extracto ante preguntas fuera de tema (TD-25).
- Los fixtures son TTS: WER/DER medidos son una cota optimista.
- Bluetooth en llamadas usa perfil de banda estrecha (se advierte en UI).
- Apps en navegador: no se puede aislar una pestaña; se graba todo el audio del navegador.
- Silenciarte en la app de la llamada no pausa tu micrófono aquí, y la app no puede detectarlo (TD-23).

## TD-30 · Consentimiento permanente por proveedor en la nube (comprobado)
La confirmación antes de enviar a un proveedor en la nube tiene la casilla «No volver a preguntar». Se guarda por
proveedor (`aiConsentSkipped` en UserDefaults), así que autorizar Codex no autoriza Claude ni Copilot. Cada tarjeta de
Inteligencia › Proveedores tiene «Confirmar antes de enviar» para revertirlo. Sin la confirmación, el análisis y el
chat se registran igualmente con consentimiento dado (`consentGiven`), porque el usuario lo concedió de forma
explícita y duradera; el envío sigue empezando solo por una acción suya. Ollama (local) nunca pide confirmación.
Verificado con una prueba del controlador (por proveedor, persiste al reabrir, se revierte) y con capturas de la hoja
y de las tarjetas.

## TD-31 · Requisito mínimo macOS 15 (compilación comprobada; ejecución en macOS 15 pendiente)
El mínimo baja de macOS 26 a **macOS 15 (Sequoia)** sin cambios de código.
- Dependencias: FluidAudio y swift-embeddings piden macOS 14; GRDB y el resto, menos.
- Con macOS 14.2 no compila: la búsqueda semántica (swift-embeddings / `MLTensor`: `XLMRoberta.ModelBundle`,
  `EncodeOptions`) y `AVAudioFile.close()` (en `SilenceCompactor`) son de macOS 15. Bajar a 14.2 exigiría ocultar la
  búsqueda semántica y condicionar ese cierre; se descartó.
- Con `.macOS(.v15)` compila todo el paquete sin errores ni avisos de disponibilidad y pasan todas las pruebas
  (ejecutadas en macOS 27). Se sigue compilando con el SDK 26.5 (TD-02).
- **Sin verificar en un Mac con macOS 15**: aspecto de SwiftUI, captura de audio del sistema (process taps,
  macOS 14.2+), Neural Engine y permisos. `LSMinimumSystemVersion` = 15.0 y el actualizador lo comprueba (TD-29).


## TD-32 · El chat con IA responde aunque la búsqueda no encuentre nada (pruebas comprobadas; IA real pendiente)
Antes, si la búsqueda local no devolvía extractos (un saludo como «Hola», o «¿de qué se habló?», que son solo
palabras vacías), el chat respondía «No encontré información…» sin llamar al proveedor, con cualquier IA.
- `Retrieval.excerpts` sigue siendo solo el resultado de la búsqueda (lo usan la respuesta local y la CLI);
  `Retrieval.context` es lo que se envía a la IA.
- Sin coincidencias en reuniones concretas (chat de una reunión o reuniones seleccionadas), `context` es una muestra
  cronológica de su transcripción (`SearchService.transcriptSample`, hasta 150 segmentos repartidos). La IA puede
  citarlos y el resumen del consentimiento lo indica.
- Sin coincidencias en toda la biblioteca solo se envía la pregunta, y el resumen del consentimiento lo dice.
- Prompt `chat-v2`: ante un saludo responde breve y ofrece ayuda (`found=false`, sin citas).
- Verificado con pruebas usando un proveedor falso. **Sin verificar con un proveedor real**: no se enviaron reuniones a
  la nube para probarlo.

## TD-33 · AEC sobre la grabación por defecto; Apple como alternativa opcional
La prueba A/B del usuario confirma el disparador: con Voice Processing de Apple activo, al iniciar la grabación
Teams deja de transmitir su voz correctamente aunque Meeting Intelligence recibe el micrófono. En una grabación
nueva con la opción desactivada, Teams vuelve a oírlo bien, pero las voces remotas quedan en las dos pistas al usar
altavoces. Esto aísla la incompatibilidad en la ruta VPIO, **sin demostrar** que la causa interna sea doble AEC,
AGC o un cambio de dispositivo. El consejo previo de desactivar la opción y ocultar texto duplicado no soluciona
el audio grabado.

Decisión: «Reducir eco de altavoces en la grabación» está activada por defecto; el micrófono se abre con
`AVAudioEngine` sin procesamiento de voz. A petición del usuario se conserva «Cancelación de eco de Apple
(Voice Processing)» como alternativa desactivada por defecto, con aviso del conflicto observado en Teams.
Activar una opción desactiva la otra; la configuración de captura también impide combinarlas (si un llamador
solicita ambas, se prioriza el AEC de grabación). SpeexDSP **1.2.1**, subconjunto AEC con FFT
smallft, fuentes oficiales sin modificar y licencia BSD incluidas en `Sources/CSpeexDSP`, filtra únicamente las
muestras copiadas del micrófono. Este filtro no utiliza dispositivos virtuales ni cambia ganancia, mute o ajustes
de la llamada. La alternativa Apple conserva su procesamiento del sistema; no se considera resuelto su conflicto.
La referencia es el audio remoto elegido por el usuario (no se amplía el alcance de captura). Se procesa después
del remuestreo/alineación y antes del WAV/transcripción provisional, en una cola compartida por ambas pistas.

Tramas de 20 ms, adelanto de referencia de 80 ms, filtro adaptativo de 300 ms con protección de doble habla de
Speex. No se añade preprocesador/AGC: la salida conserva su posición temporal. El silencio digital de pausas y
huecos sigue siendo cero. Espera máxima de referencia: 0,5 s; si falta, se conserva la voz sin filtrar y se avisa.
Referencia retenida: hasta 2 s. Al detener se drena la referencia antes del micrófono, incluida su trama parcial.
Los últimos bloques sin los 80 ms futuros de referencia se conservan sin filtrar; no se inventa una referencia
de silencio ni se emite un aviso por el final normal de ambas pistas. Regresión con trama final completa y parcial.
La preferencia `microphoneEchoCancellation` está activada por defecto. `appleVoiceProcessing` solo se activa
al elegir explícitamente la alternativa Apple. La antigua `voiceProcessing` no reactiva VPIO automáticamente.
Preferencias almacenadas contradictorias se normalizan priorizando el filtro de grabación, sin reactivar Apple
si luego se apaga dicho filtro. El AEC de grabación no se aplica a una sola pista; Apple puede elegirse también
para micrófono solo.

Validación automática: señales sintéticas con eco retardado/reverberante, voces simultáneas, sin eco acústico,
pausas de micrófono, referencia ausente, memoria limitada y escritura de WAV/transcripción provisional. La
captura física y Teams no se abren en estas pruebas. **Pendiente prueba de la nueva implementación con llamada
real**, volumen que reciben los demás, cambios de dispositivo y condiciones acústicas reales. El filtro necesita
adaptarse; puede quedar eco con altavoces saturados, latencia/reverberación fuera del filtro, deriva o sonidos de
otras aplicaciones que no estén en la referencia. No se promete eliminación total. Las grabaciones anteriores
no se modifican automáticamente.
