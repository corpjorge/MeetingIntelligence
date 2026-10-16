# Meeting Intelligence

Aplicación **nativa de macOS** (Swift 6 + SwiftUI) para grabar, transcribir, identificar participantes y analizar
reuniones de **Microsoft Teams** — sin bots, sin modificar Teams y **local por defecto**.

- Captura el **micrófono** y el **audio remoto de Teams** en pistas separadas y sincronizadas (Core Audio Process Taps).
- Transcribe localmente con **Parakeet Ultra** (FluidAudio + Core ML, Apple Neural Engine).
- Separa hablantes con **diarización offline** (pyannote community + WeSpeaker + VBx) y reconoce participantes
  registrados **solo con consentimiento** y umbrales **calibrados con tus propios datos**.
- Analiza reuniones con **Claude Code CLI, Codex CLI, Antigravity CLI u Ollama** — opcional, con confirmación explícita
  y **evidencia verificable** (cita exacta + timestamp) para cada hallazgo.
- Búsqueda local **SQLite FTS5**, chat entre reuniones con citas, exportación TXT/Markdown/JSON/SRT/PDF y un
  **servidor MCP** de solo lectura para clientes como Claude Code y Codex.

> El nombre es provisional: cámbialo en `config/app.env` (`APP_NAME`); no requiere tocar código Swift.

## Estado real (verificado el 16-oct-2026 en MacBook Pro M5 Pro, macOS 27.0.1)

| Área | Estado | Verificación |
|---|---|---|
| App macOS (SwiftUI, Design System, claro/oscuro) | ✅ Implementada | Compila; capturas de las 12 pantallas en ambos modos (modo instantánea) |
| Importar WAV/M4A/MP3/MP4 | ✅ | Pruebas + CLI |
| Transcripción Parakeet Ultra (local, ANE) | ✅ | Integración real: WER 0–9 % en fixtures sintéticos, RTFx 100–475× |
| Transcripción provisional en vivo (ventanas deslizantes Ultra) | ✅ | Prueba de integración real |
| Diarización offline + alineación palabra→hablante | ✅ | DER 6,2 % en fixture de 2 voces; 2/2 hablantes en reunión de 17,5 min |
| Reconocimiento persistente de participantes (cifrado, calibrado) | ✅ Implementado | Pruebas unitarias con embeddings sintéticos; **pendiente** validar con voces reales autorizadas |
| Captura de Teams (process tap) + micrófono, pausa, recuperación | ✅ Implementado | Pruebas de escritura WAV, alineación, remuestreo y detección real de procesos de Teams; **pendiente** prueba con llamada real (requiere tus permisos de macOS) |
| Edición de transcripción con historial | ✅ | Pruebas de persistencia |
| Identidades manuales conservadas al reprocesar | ✅ | Integración real: asignar → reprocesar → identidad conservada |
| Diccionario personalizado | ✅ | Pruebas + integración |
| Análisis IA con evidencia (Codex) | ✅ | Ejecución real con Codex CLI sobre reunión fixture |
| Análisis IA (Claude Code CLI / Antigravity / Ollama) | ✅ Implementado | Formatos de salida verificados; Claude: sesión OAuth expirada en el entorno de pruebas; Ollama no instalado |
| Chat entre reuniones (FTS5 + IA opcional) | ✅ | Pruebas |
| Servidor MCP (stdio, 2026-07-28 + 2025-11-25) | ✅ | Prueba stdio con el binario empaquetado |
| Exportación TXT/MD/JSON/SRT/PDF | ✅ | Pruebas |

61 pruebas automatizadas pasan (`scripts/test.sh`), incluidas 5 de integración con los modelos reales.

## Requisitos

- Mac con Apple Silicon, **macOS 26 o posterior** (desarrollado en macOS 27.0.1).
- **Command Line Tools** (Swift 6.4) — Xcode no es obligatorio. Con solo CLT se compila contra el SDK macOS 26.5
  incluido (ver `TECHNICAL_DECISIONS.md` › TD-02).
- ~1 GB libre para modelos (Parakeet Ultra ≈ 630 MB + diarización), descargados una vez desde Hugging Face.
- `ffmpeg` solo para regenerar los fixtures de prueba.

## Compilar y ejecutar

```bash
scripts/build-app.sh            # compila en release y crea "build/Meeting Intelligence.app"
open "build/Meeting Intelligence.app"
```

```bash
scripts/test.sh                 # suite completa (Swift Testing)
scripts/generate-fixtures.sh    # regenera los audios sintéticos de prueba (voces del sistema)
```

Primera ejecución: la bienvenida pide tu nombre y descarga los modelos. macOS pedirá **Micrófono** y
**Grabación de audio del sistema** al iniciar la primera grabación.

> Firma: por defecto el bundle se firma *ad hoc*, así que macOS vuelve a pedir permisos tras cada recompilación.
> Para conservarlos, usa una identidad de firma propia: `SIGN_IDENTITY="Mi certificado" scripts/build-app.sh`.

## CLI `mi`

Incluida en `build/Meeting Intelligence.app/Contents/MacOS/mi` (usa la misma biblioteca; otra con `MEETING_INTELLIGENCE_HOME`).

```bash
mi doctor                                   # entorno: modelos, dispositivos, procesos de Teams, permisos
mi import grabacion.m4a --title "Comité"    # importa + Ultra + diarización + reconocimiento
mi show <meetingId>                         # transcripción con hablantes y timestamps
mi search "indicador de ingresos"           # búsqueda local FTS5
mi export <meetingId> --format pdf
mi ai-providers                             # detecta Claude / Codex / Antigravity / Ollama
mi analyze <meetingId> --provider codex --share
mi ask "¿Qué compromisos asumió Carlos?" --provider ollama
mi evaluate audio.wav --reference ref.txt --rttm ref.rttm   # WER / DER / RTFx reproducibles
```

## MCP

Activa el acceso en **Ajustes › MCP** (deshabilitado por defecto) y registra el servidor:

```bash
claude mcp add --scope user meeting-intelligence -- "/Applications/Meeting Intelligence.app/Contents/MacOS/meeting-intelligence-mcp"
```

```bash
codex mcp add meeting-intelligence -- "/Applications/Meeting Intelligence.app/Contents/MacOS/meeting-intelligence-mcp"
```

Herramientas de solo lectura: `list_meetings`, `get_meeting`, `get_transcript`, `get_participants`,
`search_meetings`, `get_decisions`, `get_action_items`, `compare_meetings`. Nunca expone audio ni datos biométricos.

## Documentación

- [ARCHITECTURE.md](ARCHITECTURE.md) — módulos, flujos, concurrencia, esquema.
- [TECHNICAL_DECISIONS.md](TECHNICAL_DECISIONS.md) — decisiones y limitaciones comprobadas.
- [TESTING.md](TESTING.md) — pruebas, fixtures y métricas medidas.
- [PRIVACY.md](PRIVACY.md) — datos, consentimiento, cifrado, qué sale del Mac.
- [ROADMAP.md](ROADMAP.md) — fases y pendientes.
- [CLAUDE.md](CLAUDE.md) — reglas para continuar el desarrollo con Claude Code.
