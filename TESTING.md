# Pruebas

```bash
scripts/test.sh                 # suite completa
scripts/test.sh --filter MCP    # filtrar
scripts/generate-fixtures.sh    # regenera fixtures sintéticos (necesario para las pruebas de integración)
```

Framework: **Swift Testing** (XCTest no está disponible con Command Line Tools). Las pruebas de integración con
modelos reales se ejecutan solo si Parakeet Ultra y la diarización ya están en caché (nunca descargan en CI).

## Inventario (55 pruebas, todas pasan al 16-oct-2026)

| Suite | Cubre |
|---|---|
| Persistencia | migraciones, integridad (`foreign_key_check`, `integrity_check`), detalle, edición sin perder ASR, historial, re-transcripción sin borrar, borrado en cascada + archivos, permisos 0700/0600, recuperación tras cierre, usuario local único |
| Búsqueda FTS5 | sin acentos, prefijos, plurales, ediciones de usuario, alcance por reunión |
| Exportación | JSON completo (timestamps, origen del texto, correcciones), SRT, Markdown, TXT, PDF; sin datos biométricos |
| Utilidades / Cifrado | timecodes, normalización, diccionario por palabra completa, AES-GCM (ida y vuelta, manipulación, revocación) |
| IA | extracción JSON ruidosa (formato real de `agy`), verificación de citas, cita inventada → no confirmada, consentimiento remoto obligatorio, salida inválida registrada, chat con citas válidas, timeout de procesos, Ollama solo local |
| Servidor MCP | `initialize` legacy, `server/discover` moderno, versión no soportada (-32022), errores JSON-RPC, acceso deshabilitado por defecto, herramientas con timestamps, validación de parámetros, política por reunión |
| Escritura WAV / Alineación / Conversión | WAV legible, recuperación tras cierre, huecos, deriva, pausas, remuestreo 48→16 kHz (duración, tono, nivel), mezcla a mono |
| Detección de Teams | bundle IDs, helpers WebView2 dentro de Teams, rechazo de Outlook, catálogo HAL real |
| Segmentación y alineación | tokens→palabras, pausas/oraciones, cambio de hablante, suavizado, solapamiento, eco |
| Reconocimiento | sin calibrar → solo sugerencia, calibrado acepta/rechaza, voz ambigua no aceptada, poca voz → sugerencia |
| Integración (modelos reales) | importar→Ultra→diarización→persistencia (2 hablantes, sin nombres inventados, WER < 15 %, diccionario), silencio → vacío, español + términos en inglés, transcripción en vivo |

## Fixtures

`Fixtures/synthetic/` — generados con voces del sistema (`say`), **sin personas ni reuniones reales**:
un hablante con terminología técnica, dos hablantes alternos (+ RTTM), voces superpuestas, silencio, audio
degradado (banda telefónica + ruido rosa). Los `.wav` no se versionan (`.gitignore`); se regeneran con el script.

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

## Medir con grabaciones reales (autorizadas)

1. Graba o exporta un audio con consentimiento de todos los participantes.
2. Crea la referencia: `ref.txt` (texto) y opcionalmente `ref.rttm` (`SPEAKER <id> 1 <inicio> <duración> <NA> <NA> <hablante> <NA> <NA>`).
3. `mi evaluate audio.wav --reference ref.txt --rttm ref.rttm`.
4. Identificación: registra ≥ 2 muestras de ≥ 2 personas; mide aceptaciones correctas y **falsos reconocimientos**
   en reuniones donde participan y no participan.

## Pruebas manuales pendientes (requieren permisos o condiciones del usuario)

- Grabación real de una llamada de Teams: concesión de "Micrófono" y "Grabación de audio del sistema", niveles en
  vivo, pausa/reanudación, cambio a AirPods durante la llamada, cerrar la app grabando (debe recuperarse).
- Análisis con Claude Code CLI (iniciar sesión con `claude` en una terminal) y con Ollama (instalar y `ollama pull`).
- Configurar el MCP en Claude Code / Codex y consultar reuniones reales.

## Rendimiento

Cada etapa queda registrada en `processingJob` (duración, segundos de audio → RTFx, memoria pico del proceso).
