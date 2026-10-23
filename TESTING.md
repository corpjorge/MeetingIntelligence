# Pruebas

```bash
scripts/test.sh                 # suite completa
scripts/test.sh --filter MCP    # filtrar
scripts/generate-fixtures.sh    # regenera fixtures sintéticos (necesario para las pruebas de integración)
```

Framework: **Swift Testing** (XCTest no está disponible con Command Line Tools). La lógica de la app (servicios y
preferencias) tiene su propio target, `MeetingIntelligenceAppTests`; las vistas se verifican con capturas (TD-15). Las pruebas de integración con
modelos reales se ejecutan solo si Parakeet Ultra y la diarización ya están en caché (nunca descargan en CI).

## Inventario (138 pruebas, todas pasan al 22-oct-2026; 4 más bajo demanda)

| Suite | Cubre |
|---|---|
| Persistencia | migraciones, integridad (`foreign_key_check`, `integrity_check`), detalle, edición sin perder ASR, historial, re-transcripción sin borrar, borrado en cascada + archivos, permisos 0700/0600, recuperación tras cierre, usuario local único |
| Búsqueda FTS5 | sin acentos, prefijos, plurales, ediciones de usuario, alcance por reunión |
| Exportación | JSON completo (timestamps, origen del texto, correcciones), SRT, Markdown, TXT, PDF; sin datos biométricos |
| Utilidades / Cifrado | timecodes, normalización, diccionario por palabra completa, AES-GCM (ida y vuelta, manipulación, revocación) |
| IA | extracción JSON ruidosa (formato real de `agy`), verificación de citas, cita inventada → no confirmada, consentimiento remoto obligatorio, salida inválida registrada, chat con citas válidas, timeout de procesos, una CLI que no lee la transcripción no cierra la app (SIGPIPE), Codex aislado de `config.toml` y sin ejecución de comandos (solo funciones que esa versión conoce; sin `shell_tool`/`unified_exec` no se envía nada), modelo y esfuerzo de `config.toml` conservados, Copilot CLI sin herramientas (lista con un nombre inexistente, shell/escritura/URLs denegados), `COPILOT_HOME` aislado y variables que reactivan herramientas eliminadas, esfuerzo sin modelo rechazado antes de enviar, lectura del JSONL (último mensaje y modelo; respuesta descartada si se usó una herramienta), AWS Copilot no se confunde con GitHub Copilot, Ollama solo local |
| Servidor MCP | `initialize` legacy, `server/discover` moderno, versión no soportada (-32022), errores JSON-RPC, acceso deshabilitado por defecto, herramientas con timestamps, validación de parámetros, política por reunión |
| Escritura WAV / Alineación / Conversión | WAV legible, recuperación tras cierre, huecos, deriva, pausas, remuestreo 48→16 kHz (duración, tono, nivel), mezcla a mono |
| Compactación de silencio antes del ASR | tramos muertos inicial/intermedio/final, pausas < 1 s y voz baja (−60 dBFS) intactas, última trama parcial, remapeo de tiempos (uniones, tokens recortados), muestras conservadas idénticas, archivo sin silencio → no se copia |
| Detección de Teams | bundle IDs, helpers WebView2 dentro de Teams, rechazo de Outlook, catálogo HAL real |
| Apps de conversación | agrupación por `.app` (Teams, Zoom, Chrome, WebKit, app desconocida), exclusión de esta app, orden por actividad, HAL real |
| Detección de llamadas | inicio tras 3 s, prueba breve ignorada, dictado (solo micrófono) ignorado, cambio a AirPods sin falso fin, fin tras 25 s, app cerrada, apps ignoradas, FaceTime |
| Pausa del micrófono | silencio escrito, línea de tiempo intacta, intervalo registrado |
| Recordatorio de silencio en la llamada | solo con micrófono + audio de una app/sistema, oculto en pausa o descartado, texto con la app y ⌃⌘M |
| Migración v2 y esfuerzo de IA | columnas/tabla nuevas, app de origen, flags de esfuerzo por CLI, sin flags que omitan permisos, esfuerzo registrado en el análisis |
| Segmentación y alineación | tokens→palabras, pausas/oraciones, cambio de hablante, suavizado, solapamiento, eco |
| Identidades manuales al reprocesar | re-mapeo por solapamiento, empate/poca evidencia → no se aplica, mayoría mutua (división desigual: solo la parte mayoritaria hereda; a partes iguales: ninguna; persona absorbida por un cluster con nombre → desconocida), hablantes con el mismo nombre lo conservan, sin doble conteo, solo asignaciones manuales vigentes (también tras deshacer una fusión) |
| Reconocimiento | sin calibrar → solo sugerencia, calibrado acepta/rechaza, voz ambigua no aceptada, poca voz → sugerencia |
| Historial del chat | hilos separados, respuesta nula (búsqueda fallida), borrar historial, borrar una reunión elimina su hilo y los mensajes que la citan |
| Búsqueda semántica: índice y fusión | vectores ida y vuelta, coseno, pendientes por modelo, reindexado tras editar, cascada al borrar, alcance y umbral, fusión que no pierde resultados de FTS5 |
| Refuerzo acústico: reglas | palabra común del idioma nunca reemplazada, varias palabras sí, puntuación conservada, solo el tramo coincidente |
| Borrado y espacio en disco | resumen previo (tamaño, muestras, chat), muestras de voz conservadas o borradas, `VACUUM` devuelve el espacio, carpetas huérfanas y temporales viejos |
| Actualización de modelos | hash de blob git, plan solo sobre lo descargado (variantes y ONNX ignorados), preparación aparte, intercambio, confirmación, vuelta atrás, recuperación tras un cierre, modelos fijados, paginación |
| Tokens partidos por la compactación | "▁¿" y "." se pegan a su palabra; piezas con letras y palabras nuevas no se mueven |
| App: preferencias | valores por defecto seguros (solo sugerencias, consentimiento, descargas opcionales), persistencia entre arranques, "conservar siempre" = nil, modo de captura heredado, opciones de procesamiento |
| App: consentimiento de IA | análisis en la nube espera confirmación (rechazar no envía nada ni guarda análisis), confirmar lo ejecuta, Ollama sin preguntar, chat: rechazar → respuesta local sin enviar, confirmar → respuesta con citas, proveedor elegido recordado |
| App: cola de procesamiento | una reunión a la vez con el pipeline real, sin duplicados, cancelar una en cola, error informado por reunión |
| App: sugerencias de llamada | sugerir grabar solo si está activado (nunca graba solo), fin de llamada limpia la sugerencia y no ofrece detener si no se graba, apps ignoradas persistidas, aceptar entrega la app al flujo del usuario |
| Actualizaciones de la app | versiones (pre-releases, `1.0` = `1.0.0`, tags inválidos), lectura de releases de GitHub (borradores, sin firma o sin versión → ignorados; pre-releases incluidos; notas «Novedades» con líneas unidas como en Markdown, sobre `docs/releases/0.2.0.md`), firma Ed25519 (versión, ZIP y clave atados), preparación válida y rechazos (otra clave, versión o app distinta, macOS mínimo, tamaño), intercambio atómico y limpieza, ubicaciones no instalables (App Translocation, sin permiso), firma de código manipulada y ad hoc |
| App: actualizaciones | aviso solo para búsquedas automáticas, «Ahora no» y «Omitir esta versión» (la búsqueda manual la ofrece igual), al día, fallo silencioso en segundo plano y visible al buscar, un fallo en segundo plano conserva la versión ya ofrecida, nunca descarga donde la app no se puede reemplazar, descarga → verificada → no se instala mientras se graba → instala, reinicia y cierra; el arranque siguiente informa y borra la versión anterior; búsqueda automática activada por defecto |
| Integración (modelos reales) | importar→Ultra→diarización→persistencia (2 hablantes, sin nombres inventados, WER < 15 %, diccionario), silencio → vacío, español + términos en inglés, frases cortas aisladas siguen en español con marcas en la línea de tiempo original (TD-22), transcripción en vivo, reprocesar conserva identidades manuales |

## Fixtures

`Fixtures/synthetic/` — generados con voces del sistema (`say`), **sin personas ni reuniones reales**:
un hablante con terminología técnica, dos hablantes alternos (+ RTTM), voces superpuestas, silencio, audio
degradado (banda telefónica + ruido rosa), respuesta corta entre silencios y frases cortas aisladas en silencio digital
(`es_isolated_greeting`, `es_isolated_word`). Los `.wav` no se versionan (`.gitignore`); se regeneran con el script.

## Métricas medidas (reproducibles con `mi evaluate`)

Equipo: MacBook Pro M5 Pro, macOS 27.0.1, FluidAudio 0.17.7, Parakeet Ultra (ANE).

| Fixture | Duración | WER | DER | RTFx ASR | Notas |
|---|---|---|---|---|---|
| es_single_speaker | 17,7 s | 0 % | — | 100× | 45/45 palabras; incluye términos en inglés (endpoint, pull request, Kubernetes, API) |
| es_two_speakers | 22,6 s | 9,26 % | 6,17 % | 191× | errores: "response"→"responsa", "QA"→"Cuba", "quince"→"15"; confusión de hablantes 0 s |
| es_noisy (banda telefónica + ruido) | 17,7 s | 2,22 % | — | 148× | "endpoint"→"encoint" |
| es_overlap | 4,2 s | 12,5 % | — | 78× | pierde 2 palabras del tramo solapado |
| silence | 12 s | — | — | 233× | transcripción vacía (sin alucinaciones) |
| reunión larga (concatenada) | 17,5 min | — | — | **475×** | diarización 8,7 s; 2/2 hablantes; total 28,5 s con carga de modelos; **RSS pico 403 MB** |

WER: distancia de edición sobre palabras normalizadas (minúsculas, sin acentos ni puntuación). DER: por tramas de
10 ms, sin collar, mapeo óptimo de etiquetas. Los fixtures TTS son más limpios que una reunión real: estas cifras son
una **cota optimista**. No se declara precisión sobre reuniones reales sin mediciones con grabaciones autorizadas.

## Frases cortas en otro idioma (TD-22)

Medido el 16-oct-2026 (macOS 27.0.1, FluidAudio 0.17.7, Parakeet Ultra), con un arnés temporal que no se versiona:

| Audio | Decodificado tal cual (antes) | Con compactación de silencio (ahora) |
|---|---|---|
| `es_isolated_greeting` (Eddy, "Aló, ¿cómo está?") | "Hello, como está?" | "Aló, ¿cómo está?" (inicio en 3,20 s) |
| `es_isolated_word` (Paulina, "Vale.") | "Valeu, né?" | "Vale." (inicio en 3,36 s) |
| 24 diálogos sintéticos (frases entre silencios largos) | WER 10,7 % | WER 1,9 % |
| 80 frases aisladas en 22 s de silencio | WER 26,6 % (51/80 exactas) | WER 20,1 % (62/80) |
| Fixtures previos | — | mismo texto |
| Reunión real autorizada (solo verificación local; no se citan sus palabras) | remoto: saludo en francés · micrófono: frase en inglés | remoto: saludo en español · micrófono: frase corta en español (sin referencia) |

Pasar `language: .spanish` no cambia el texto en español frente a `nil` (167/169 idénticos; los otros 2 pasan de
cirílico a `<unk>`); bajar el nivel a −40 dBFS no empeora el resultado. Pendiente: medir la tasa de deriva en
grabaciones reales autorizadas con respuestas cortas (no basta un solo caso).
Seguimiento (21-oct-2026): redecodificación con contexto y arreglo de palabras estiradas sobre huecos, TD-26.

## Mediciones bajo demanda (TD-24, TD-25, TD-26)

Los datos son voces sintéticas (`say`) generadas en una carpeta temporal; no se versionan.

```bash
MI_BOOST_DATA=<dir con data/*.wav|txt y terms.txt> scripts/test.sh --filter VocabularyBoostExperiment   # → report-*.txt
MI_LANG_DATA=<dir con data/*.wav|txt y ctx/v1..4.wav> scripts/test.sh --filter LanguageDriftExperiment  # → report.txt
MI_E5_MODELS=<carpeta con models/intfloat/multilingual-e5-small> scripts/test.sh --filter SemanticEngineIntegrationTests
MI_NETWORK_TESTS=1 scripts/test.sh --filter ModelUpdateIntegrationTests   # Hugging Face real, sobre una COPIA de CTC 110M
mi models                                   # versiones de los modelos instalados (consulta Hugging Face)
mi process <id> --boost-vocabulary        # refuerzo en el pipeline real
mi semantic-index && mi ask "<pregunta>" --semantic
```

Resultados y conjuntos en `TECHNICAL_DECISIONS.md` (TD-24, TD-25, TD-26).

## Medir con grabaciones reales (autorizadas)

1. Graba o exporta un audio con consentimiento de todos los participantes.
2. Crea la referencia: `ref.txt` (texto) y opcionalmente `ref.rttm` (`SPEAKER <id> 1 <inicio> <duración> <NA> <NA> <hablante> <NA> <NA>`).
3. `mi evaluate audio.wav --reference ref.txt --rttm ref.rttm`.
4. Identificación: registra ≥ 2 muestras de ≥ 2 personas; mide aceptaciones correctas y **falsos reconocimientos**
   en reuniones donde participan y no participan.

## Verificación en vivo realizada

- `mi doctor` lista en tiempo real las apps registradas en el audio del sistema: con `afplay` reproduciendo, aparece
  como "reproduce audio"; Teams se agrupa con sus 5 procesos; Chrome, Edge y Safari/WebKit aparecen como audio compartido.
- Silencio en Teams (TD-23): con una sonda del HAL y de `AVAudioApplication` durante una llamada real, 3 ciclos de
  silenciar/activar en Teams no cambiaron ninguna señal legible; Teams mantuvo el micrófono abierto. Por eso el aviso
  es un recordatorio estático. El componente se verifica con `MI_SNAPSHOT_DIR` (`recording-mute-reminder-light/dark.png`)
  porque la vista de grabación en vivo necesita una captura real.
- Ajustes: el modo de capturas renderiza aparte las páginas Transcripción y Modelos (`settings-*-light/dark.png`);
  con `MI_SNAPSHOT_CHECK_MODELS=1` consulta antes las versiones en Hugging Face.
- Las ventanas se capturan con ScreenCaptureKit, limitado a las del propio proceso (`SCShareableContent.currentProcess`,
  sin permiso de grabación de pantalla), para que se vean la barra lateral y la vibrancia; `cacheDisplay` es la
  alternativa.
- Capturas del README (`docs/images/`): biblioteca aparte (`MEETING_INTELLIGENCE_HOME`) con 3 reuniones sintéticas
  (`say`, personas ficticias) procesadas con `mi import` y `mi process --boost-vocabulary`. Los nombres se asignaron a
  mano. Hay un análisis real con `mi analyze --provider codex --share` y preguntas del chat con `mi ask … --save`. Las
  preferencias del modo de capturas son una suite propia de UserDefaults.
- Baja confianza del ASR: `MI_SNAPSHOT_MEETING=<id>` elige la reunión de las capturas; la primera fila marcada se
  renderiza aparte (`transcript-low-confidence-light/dark.png`) porque suele quedar fuera de la primera pantalla.
- API de Teams para apps de terceros (TD-23): no aparece en Configuración › Privacidad de la cuenta de prueba, que es
  de una organización, ni buscando "API" o "terceros". Una sonda pasiva no logró conectar al 127.0.0.1:8124 en 318 s.

- Actualización de punta a punta (TD-29): la app 0.2.0 compilada en release, en una carpeta temporal y con biblioteca
  aparte. Un servidor local publicaba una 0.2.1 firmada con la clave real:
  ```bash
  open -n --env MEETING_INTELLIGENCE_HOME=<dir> --env MI_UPDATE_API=http://127.0.0.1:8765 --env MI_UPDATE_E2E=1 "<dir>/Meeting Intelligence.app"
  ```
  `MI_UPDATE_E2E=1` acepta la descarga y la instalación (solo con API loopback). La app detectó, descargó, verificó,
  reemplazó y reinició en aproximadamente 1 s. La 0.2.1 registró «installed» y borró la anterior; sin cuarentena y
  con firma válida. Con una 0.2.2 de firma alterada no cambió nada. El aviso y la hoja tienen capturas
  (`update-banner-*`, `update-sheet-*`, `settings-general-*`).
  Limitación de esa prueba: `MI_UPDATE_E2E=1` instala sin la hoja abierta. En la actualización real 0.2.0 → 0.2.1
  desde la hoja, la app se quedó en «Instalando y reiniciando…»: AppKit ignora `NSApp.terminate` mientras hay una
  hoja adjunta. Ahora se cierra la hoja antes de salir; reproducido y verificado con una hoja SwiftUI mínima.

## Pruebas manuales pendientes (requieren permisos o condiciones del usuario)

- Instalar y usar la app en un Mac con **macOS 15** (requisito mínimo desde la 0.2.3, TD-31): grabar con micrófono y
  audio del sistema, procesar, búsqueda semántica y actualizar desde la app.

- Actualización real 0.2.1 → 0.2.2 desde `/Applications` usando la hoja: confirmar que se cierra y reinicia sola (en la
  0.2.0 → 0.2.1 el reemplazo funcionó pero el reinicio no, TD-29) y qué permisos vuelve a pedir macOS.

- Detección de llamadas: unirse a una llamada en Teams, Zoom y Meet (Chrome) y comprobar la sugerencia de grabar y,
  al colgar, la sugerencia de detener; registrar qué procesos usan el micrófono en cada app.
- Grabación real de una llamada de Teams: concesión de "Micrófono" y "Grabación de audio del sistema", niveles en
  vivo, pausa/reanudación, cambio a AirPods durante la llamada, cerrar la app grabando (debe recuperarse); el
  recordatorio de silencio aparece, "Pausar mi micrófono" pausa y la ✕ lo oculta solo en esa grabación.
- Silencio en Zoom: repetir la sonda de TD-23 en una llamada de Zoom (no se probó).
- Análisis con Claude Code CLI (iniciar sesión con `claude` en una terminal) y con Ollama (instalar y `ollama pull`).
- Configurar el MCP en Claude Code / Codex y consultar reuniones reales.

## Rendimiento

Cada etapa queda registrada en `processingJob` (duración, segundos de audio → RTFx, memoria pico del proceso).
