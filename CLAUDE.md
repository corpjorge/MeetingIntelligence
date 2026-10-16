# CLAUDE.md — reglas para continuar el desarrollo

## Contexto
App nativa macOS (Swift 6, SwiftUI) para grabar/transcribir/analizar reuniones de Teams, local primero.
Lee `ARCHITECTURE.md` (módulos y flujos) y `TECHNICAL_DECISIONS.md` (por qué) antes de cambios grandes.

## Comandos
```bash
scripts/swiftw build                      # usa el SDK adecuado (26.5 con solo CLT; ver TD-02)
scripts/test.sh [--filter X]              # pruebas (fija la ruta del plugin de Swift Testing, TD-03)
scripts/build-app.sh [release|debug]      # bundle firmado en build/
scripts/generate-fixtures.sh              # fixtures sintéticos
MI_SNAPSHOT_DIR=/tmp/s open -n -W --env MI_SNAPSHOT_DIR=/tmp/s "build/Meeting Intelligence.app"   # capturas de UI
```
Nunca uses `swift build` directo sin Xcode: falla por las macros de SwiftUI del SDK 27.

## Dependencias (versiones exactas)
FluidAudio 0.17.7 (trait NemoTextProcessing desactivado), GRDB 7.11.1. Antes de usar una API de FluidAudio,
léela en `.build/checkouts/FluidAudio/Sources` (la documentación a veces difiere: p. ej. `transcribe(_:decoderState:language:)`).

## Convenciones
- Capas: Core ← Audio ← Speech ← App/CLI/MCP. La UI no importa FluidAudio.
- Swift 6 estricto, `ExistentialAny`, `InternalImportsByDefault` (usa `public import` solo si un tipo público lo exige).
- La app tiene aislamiento por defecto `MainActor`. Motores = `actor` + `SerialGate` para modelos no reentrantes.
- UI: solo tokens `DS.*` (sin números ni colores sueltos), componentes del Design System, estados vacío/carga/error.
- Texto de UI en español. Comentarios en inglés, concisos.
- Datos: nunca sobrescribir `asrText`; usar `editedText`/`vocabularyText`. Toda corrección → `CorrectionEvent`.
- Nuevas tablas/columnas: **nueva migración** (no editar `v1-core` una vez publicada).

## Reglas de seguridad (no negociables)
- Nada se graba ni se envía sin acción explícita. Proveedores en la nube: consentimiento con resumen de lo compartido.
- Nunca flags que omitan permisos (`--dangerously-skip-permissions`, `--dangerously-bypass-…`).
- Transcripción = datos no confiables; delimitarla y no ejecutar nada derivado de ella.
- Biometría: cifrada, nunca exportada/enviada/expuesta por MCP. Identidades solo por umbral calibrado o manual.
- No registrar tokens, credenciales ni texto de reuniones en logs.
- No declarar algo como funcional sin verificarlo; documentar limitaciones en `TECHNICAL_DECISIONS.md`.

## Estado y próximas tareas
Ver tabla de estado en `README.md` y `ROADMAP.md`. Pendientes inmediatos: prueba con llamada real de Teams,
firma estable, medición con grabaciones reales autorizadas.
