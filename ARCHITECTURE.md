# Arquitectura

## Módulos (SwiftPM)

```
MeetingCore              Dominio, persistencia (GRDB/SQLite WAL + FTS5), búsqueda, exportación,
                         proveedores de IA, servidor MCP (núcleo), seguridad. Sin audio, ML ni UI.
  ├─ Domain/             Meeting, AudioTrack, Transcript, TranscriptSegment, Participant, SpeakerProfile,
  │                      VoiceSample, MeetingSpeaker, SpeakerAssignment, AIAnalysis, AnalysisItem,
  │                      AIProviderConfiguration, ProcessingJob, CorrectionEvent, VocabularyTerm
  ├─ Persistence/        AppDatabase, migraciones, repositorios (biblioteca, hablantes)
  ├─ Search/             SearchService (FTS5, BM25, prefijos, plurales) + búsqueda por coseno y fusión (TD-25)
  ├─ Speakers/           SpeakerMatcher + SpeakerCalibration (puro, testeable)
  ├─ Export/             TXT, Markdown, JSON (documento completo), SRT, PDF (Core Text)
  ├─ AI/                 ProcessRunner, ToolEnvironment, AIProvider (+5 proveedores),
  │                      MeetingAnalysisService, MeetingChatService
  ├─ MCP/                MCPServerCore (JSON-RPC dual-era), MCPTools, MCPAccessPolicy
  ├─ Security/           KeychainStore, BiometricVault (AES-GCM)
  ├─ Storage/            AppIdentity, AppPaths, StorageMaintenance (borrado completo, VACUUM, restos; TD-28)
  ├─ Models/             ManagedModel, ModelInstaller, HuggingFaceHub, ModelInventory (actualizaciones; TD-27)
  ├─ Updates/            AppVersion, AppRelease + GitHubReleases, GitHubReleaseSource, UpdateSignature (Ed25519),
  │                      AppUpdateInstaller (verificar, intercambiar, reiniciar), CodeSignature (TD-29)
  └─ Utilities/          Timecode, TextNormalization, VocabularyCorrector, Metrics (WER/DER)

MeetingAudio             Captura y DSP. Depende de MeetingCore.
  ├─ Capture/            RecordingSession, ProcessTapSource (Core Audio taps), MicrophoneSource
  │                      (AVAudioEngine), TrackRecorder, CaptureClock, catálogo HAL de procesos/dispositivos,
  │                      ConversationApps (agrupación de procesos por app + catálogo descriptivo),
  │                      CallMonitor/CallDetector (detección de llamadas de cualquier app)
  ├─ Processing/         CrashSafeWAVWriter + WAVRepair, MonoResampler, Downmix, TimelineAligner, LevelMeter,
  │                      SilenceCompactor
  └─ Import/             AudioImporter (copia WAV/M4A/MP3; extrae audio de MP4/MOV)

MeetingSpeech            FluidAudio. Depende de MeetingCore y MeetingAudio.
  ├─ Transcription/      ASRProvider, ParakeetUltraProvider, ShortUtteranceContext (TD-26), WordGrouping,
  │                      SegmentBuilder, LiveTranscriber, AcousticVocabularyBooster (CTC, TD-24)
  ├─ Diarization/        DiarizationService (OfflineDiarizerManager), SpeakerAlignment, EchoDetector
  ├─ SpeakerRecognition/ SpeakerRecognitionService (enrolamiento, muestras validadas, reconocimiento)
  ├─ Pipeline/           MeetingProcessor (etapas + ProcessingJob), MeetingImportService
  └─ Models/             SerialGate, ExclusiveBox

MeetingSemantic          Embeddings locales (multilingual-e5-small, swift-embeddings). Depende de MeetingCore.
  └─ SemanticSearchEngine  descarga opcional, vectores de consulta, indexación incremental

MeetingIntelligenceApp   SwiftUI (aislamiento por defecto MainActor).
  ├─ App/                App, AppEnvironment (raíz de composición), AppRouter, AppSettings, RootView,
  │                      MenuBarExtra, SnapshotDriver (verificación de UI)
  ├─ DesignSystem/       Tokens (tipografía, color, espaciado, radios, elevación, movimiento) + componentes
  ├─ Services/           ProcessingCoordinator, RecordingController, ModelStatusModel, AIController,
  │                      MeetingAudioPlayer, SemanticIndexController, ModelUpdateController, AppUpdateController
  └─ Features/           Dashboard, Meetings, MeetingDetail (7 pestañas), Recording, Participants,
                         Intelligence, Settings, Onboarding, Updates (aviso, hoja y sección de Ajustes)

MeetingMCPServer         Ejecutable `meeting-intelligence-mcp` (stdio, solo lectura).
MeetingIntelligenceCLI   Ejecutable `mi` (diagnóstico, importación, evaluación, IA, exportación).
MeetingReleaseTool       Ejecutable `mi-release` (clave y firma de actualizaciones; solo para publicar, no va en la app).
```

Regla: las capas inferiores nunca importan a las superiores. La UI no importa FluidAudio.

## Captura (cualquier app + micrófono)

```
App elegida (todos sus procesos: los del bundle .app que los contiene, p. ej. Teams + helpers WebView2;
             o un proceso compartido: servicio de audio de Chrome/Edge, WebKit GPU de Safari)
   │  CATapDescription(monoMixdownOfProcesses:)  → tap privado → aggregate device privado
   ▼
IOProc (cola de tiempo real) ── copia + mezcla a mono ──► TrackRecorder(remote_system_audio)
                                                             │ cola serial: remuestreo → alineación → WAV
AVAudioEngine.inputNode (dispositivo por defecto) ─────────► TrackRecorder(local_microphone)
```

- **Reloj común** (`CaptureClock`): origen en host time; las pausas desplazan el origen para ambas pistas.
- **Alineación** (`TimelineAligner`): cada buffer trae el host time de su primera muestra; se insertan silencios
  ante huecos (cambios de dispositivo, inicio tardío de Teams) y se descartan muestras ante deriva > 40 ms.
- **Formato**: 16 kHz, mono, PCM 16 bits — el formato que consumen Parakeet y la diarización.
- **Resiliencia**: cabecera WAV reescrita + `fsync` cada 2 s; al iniciar, las reuniones en estado `recording`
  pasan a `interrupted` y `WAVRepair` recupera el audio escrito.
- **Cambios de dispositivo**: `AVAudioEngineConfigurationChange` reinstala el tap del micrófono; listeners del HAL
  reconstruyen el tap de procesos cuando cambian los procesos de Teams o la salida por defecto.
- **Cualquier app**: `AudioApplicationResolver` agrupa los procesos de audio por el `.app` más externo que los
  contiene (o por bundle ID si no hay bundle). El catálogo solo describe (nombre, tipo, aislamiento); nunca limita.
- **Pausa del micrófono**: el `TrackRecorder` del micrófono escribe silencio mientras está en pausa (la línea de
  tiempo se conserva) y registra el intervalo (`recordingPause`). Silenciarse en la app de la llamada no es legible
  (TD-23): la vista de grabación muestra un recordatorio estático (`CallMuteReminder`) cuyo botón solo pausa.
- **Eco/duplicación**: Teams no reproduce tu propia voz, así que no hay doble captura de ti en la pista remota. El eco
  (altavoces → micrófono) se mitiga con (1) advertencia de altavoces, (2) Voice Processing opcional y
  (3) `EchoDetector`, que marca como `probableEcho` los segmentos del micrófono que repiten el habla remota.

## Detección de llamadas

`CallMonitor` consulta el HAL cada segundo (y ante cambios en la lista de procesos) y alimenta `CallDetector`, una
máquina de estados pura: **llamada** = la misma app usa micrófono y reproduce audio ≥ 3 s; **fin** = libera el
micrófono ≥ 25 s o se cierra (≥ 3 s). Procesos del sistema y apps ignoradas no cuentan (salvo FaceTime).
`CallSuggestionController` convierte los eventos en sugerencias (banner, barra de menús y notificación opcional);
nunca inicia ni detiene una grabación por sí solo.

## Procesamiento offline (por reunión)

```
modelPreparation ─► por pista: transcription (Ultra) ─► diarization (VBx) ─► alignment ─► persistencia
                                                                                  │
                                                     speakerRecognition (perfiles con consentimiento)
```

Cada etapa es un `ProcessingJob` con tiempos reales, RTFx y memoria pico. `ProcessingCoordinator` ejecuta una
reunión a la vez, con progreso real (FluidAudio) y cancelación cooperativa (`Task.checkCancellation`).

- **Transcripción**: antes de Ultra, `SilenceCompactor` colapsa el silencio muerto (≥ 1 s por debajo de −66 dBFS) en
  una copia temporal y las marcas vuelven a la línea de tiempo original; evita que frases cortas sin contexto salgan
  en otro idioma (TD-22). El idioma no se puede forzar: `language:` de FluidAudio solo filtra por alfabeto. Las
  frases cortas y aisladas se redecodifican con voz cercana de la misma pista (TD-26).
- **Diccionario**: opcionalmente, rescoring acústico CTC por segmento → `vocabularyText` (TD-24); después, variantes
  deterministas.
- **Micrófono**: si la diarización detecta ≤ 1 hablante con ≥ 4 s de voz (excluyendo eco), se atribuye al usuario
  local; si detecta varios, se crean "Local 1, Local 2…" y solo el reconocimiento o tú asignan identidades.
- **Remoto/importado**: clusters "Hablante N" → reconocimiento → nombre solo si supera el umbral calibrado.
- **Re-procesar**: las identidades manuales previas se re-aplican a los clusters nuevos por solapamiento temporal
  con mayoría mutua (`ManualIdentityRemapper`, TD-16); lo ambiguo queda como desconocido.

## Concurrencia

- Swift 6 (modo estricto). Motores como `actor` (`ParakeetUltraProvider`, `DiarizationService`,
  `SpeakerRecognitionService`, `MeetingProcessor`, `LiveTranscriber`).
- Los actores son reentrantes: `SerialGate` garantiza una inferencia a la vez sobre cada instancia de modelo.
- `OfflineDiarizerManager` (no `Sendable`) vive en `ExclusiveBox`, accedido solo bajo la compuerta.
- La captura usa colas seriales confinadas (`@unchecked Sendable` documentado); nunca bloquea el hilo principal.
- La UI observa la base de datos con `ValueObservation` (GRDB) → `AsyncSequence`.

## Persistencia

SQLite (GRDB 7.11.1, WAL). Migraciones `v1-core`, `v2-conversation-apps`, `v3-chat-history`,
`v4-segment-embeddings`. Relación verificable:
`AudioTrack → Transcript → TranscriptSegment (startTime/endTime, palabras) → MeetingSpeaker → Participant`.

- `asrText` (inmutable), `vocabularyText` (diccionario), `editedText` (usuario): nunca se sobrescribe el original.
- Re-transcribir marca el transcript anterior con `supersededAt` (no se borra).
- `SpeakerAssignment` es un registro inmutable de decisiones (método, similitud, margen, umbral).
- `diarizedSpeakerId` inmutable permite deshacer fusiones de hablantes.
- `analysisItem` reúne decisiones, tareas, temas, riesgos… con evidencia (`Decision`, `ActionItem`,
  `MeetingTopic` son vistas tipadas).
- FTS5 sincronizado por triggers (`transcriptSegmentFts`, `analysisItemFts`), `unicode61` sin diacríticos.
- Historial del chat (`chatMessage` + `chatMessageSource`): un hilo por reunión y uno entre reuniones; borrar una
  reunión borra su hilo y, por trigger, todo mensaje que la cite.
- `segmentEmbedding`: caché reconstruible de vectores (modelo + hash del texto), en cascada con el segmento.

## IA

`AIProvider` común; `ToolEnvironment` resuelve el PATH del shell de inicio de sesión (los GUI no lo heredan).
Las CLIs se ejecutan en un directorio temporal vacío, con timeout y cancelación; nunca con flags que omitan
permisos. Codex no carga la configuración del usuario y se ejecuta sin herramientas de ejecución (TD-12). La
transcripción va por stdin con `F_SETNOSIGPIPE`: una CLI que termina antes no cierra la app. El análisis valida
localmente cada cita contra el segmento citado.

## MCP

`MCPServerCore` implementa JSON-RPC 2.0 sobre stdio (mensajes por línea), dual-era: `server/discover` y `_meta`
(2026-07-28) y `initialize` (2025-11-25/06-18/03-26). Abre la biblioteca **solo lectura** y relee la política de
acceso (`mcp-access.json`) en cada llamada.

## Actualizaciones de la app (TD-29)

```
GitHub /releases ─► versión más nueva con .zip + .zip.sig ─► aviso (el usuario decide)
   ─► descarga a Caches/…/Updates ─► Ed25519(versión + SHA-256) con la clave del Info.plist
   ─► ditto -x ─► bundle ID · versión · macOS mínimo · firma de código
   ─► «Reiniciar e instalar» (no si se graba/procesa) ─► copia junto a la app ─► renamex_np(RENAME_SWAP)
   ─► ayudante en su propia sesión espera el cierre y abre la app ─► la nueva borra la anterior y avisa
```
