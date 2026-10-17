# Privacidad y seguridad

Principio: **local primero**. Nada sale del Mac salvo que lo autorices explícitamente para un análisis de IA en la nube.

## Qué se guarda y dónde

| Dato | Ubicación | Protección |
|---|---|---|
| Audio (`local_microphone.wav`, `remote_system_audio.wav`, importados) | `~/Library/Application Support/MeetingIntelligence/Recordings/<id>/` | Permisos 0700/0600, FileVault; conservación configurable |
| Transcripciones, hablantes, análisis, historial | `Library.sqlite` (misma carpeta) | 0600, `secure_delete`, FileVault |
| Huellas de voz (embeddings) | `voiceSample`, `meetingSpeaker` | **AES-GCM**; clave de 256 bits en el Llavero (solo este dispositivo) |
| Preferencias | `UserDefaults` | Sin secretos |
| Modelos | `~/Library/Application Support/FluidAudio/Models/` | Públicos (Hugging Face, FluidInference) |
| Copia temporal de una pista sin silencios largos (solo durante su transcripción, TD-22) | `$TMPDIR/mi-asr-<uuid>.wav` | Directorio del usuario 0700; se borra al terminar la transcripción, también si falla |

No se registran tokens, credenciales ni texto de transcripciones en los logs del sistema.

## Grabación

- Nunca empieza sola: requiere una acción explícita y (por defecto) confirmar que informaste a los participantes.
- Indicador rojo en la barra de menús y en la app mientras se graba.
- Se captura solo la **app que elijas** (o la app detectada en llamada); "todo el sistema" se elige explícitamente y
  queda registrado. En navegadores se graba todo lo que suene en el navegador (se advierte).
- La detección de llamadas solo lee qué apps usan micrófono y audio (sin permisos ni contenido) y únicamente sugiere.
- "Pausar mi micrófono" deja de grabar tu voz sin detener la grabación; el intervalo queda registrado.
  Silenciarte en Teams/Zoom **no** lo pausa y la app no puede detectarlo (TD-23); mientras grabas se muestra un recordatorio.
- No se agregan bots, no se modifica ni inyecta nada en las apps de videollamada y no existe ningún mecanismo para ocultar la
  grabación a herramientas de supervisión.

## Datos biométricos (perfiles de voz)

- Se crean **solo** con consentimiento registrado (texto de consentimiento + fecha) y muestras autorizadas.
- Se actualizan únicamente con muestras **validadas** por ti.
- Revocar el consentimiento borra todas las huellas; eliminar el perfil lo borra por completo.
- Conservación configurable por perfil (90/180/365 días sin uso).
- Nunca se exportan, nunca se envían a proveedores de IA y nunca se exponen por MCP.
- Una identidad solo se asigna automáticamente si supera un umbral calibrado con tus datos; si no, se muestra
  "Participante desconocido". Un LLM nunca decide identidades.

## Proveedores de IA

- Opcionales y opt-in. Antes de cada envío a un proveedor en la nube (Claude Code, Codex, Antigravity) se muestra
  **exactamente qué se compartirá**; sin confirmación no se envía nada.
- Ejecutar un CLI en tu Mac **no** implica que el modelo sea local: esos modelos procesan los datos en la nube.
- Ollama solo acepta endpoints locales (127.0.0.1/localhost).
- Se envía solo texto (transcripción o extractos); nunca audio ni datos biométricos.
- Los agentes se ejecutan sin herramientas ni permisos de sistema y la transcripción se trata como contenido no
  confiable: las instrucciones que aparezcan en ella no se ejecutan.

## MCP

Deshabilitado por defecto. Solo lectura. Puede limitarse a reuniones concretas. Ten en cuenta que el cliente MCP
(Claude Code, Codex…) envía a su modelo lo que consulte.

## Eliminación

- Eliminar una reunión borra su audio, transcripción, hablantes y análisis.
- Eliminar un participante borra su perfil de voz y deja sus intervenciones como "desconocido".
- Conservación de audio: se puede borrar automáticamente el audio de reuniones ya transcritas tras N días.
