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

## Limitaciones comprobadas
- ASR monocanal pierde palabras en habla **superpuesta** (fixture: 2 de 16 palabras).
- Los fixtures son TTS: WER/DER medidos son una cota optimista.
- Bluetooth en llamadas usa perfil de banda estrecha (se advierte en UI).
- Las reasignaciones manuales de identidad se recalculan al **re-procesar** una reunión (las correcciones de texto
  y el historial se conservan).
