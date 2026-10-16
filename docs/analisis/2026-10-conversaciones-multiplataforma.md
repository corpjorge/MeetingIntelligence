# Análisis ejecutivo — Conversaciones multiplataforma, detección de llamadas e identidad

**Rama:** `feature/conversaciones-multiplataforma` · **Fecha:** 16-oct-2026 · **Estado:** propuesta, pendiente de aprobación

## 1. Resumen

- **Objetivo:** pasar de "grabador de Teams" a **grabador de conversaciones**: Teams, Zoom, Google Meet y Webex en
  navegador, Slack, FaceTime y reuniones presenciales. Se mantienen los principios: local primero, sin bots y sin
  modificar las apps de terceros.
- **Pieza central:** un **monitor de llamadas** basado en Core Audio que detecta qué app usa el micrófono y emite
  audio a la vez. **No requiere permisos nuevos** y sirve para sugerir el inicio y el fin de la grabación.
- **Identidad:** persona con **correo opcional**, enriquecida (si lo autorizas) con los invitados del calendario. Ni el
  calendario ni la interfaz de otra app asignan identidades: solo ofrecen candidatos.
- **Opcional y experimental:** leer por Accessibility el estado de silencio y la lista de participantes de Teams o Zoom,
  con criterios explícitos para seguir o descartar.
- **Riesgo principal:** en los **navegadores** y en **Safari/FaceTime** el audio sale de procesos compartidos, así que la
  captura no puede limitarse a una sola pestaña o llamada. Se advertirá en la interfaz.

## 2. Punto de partida

| Hoy | Limitación |
|---|---|
| `RemoteCaptureTarget` = `teams` / `systemWide` / `none` | Teams está fijado en el código |
| `CaptureScope.teamsProcesses` y textos de UI centrados en Teams | La app no comunica que sirve para otras plataformas |
| `AudioProcessCatalog.isTeams` (bundle ID **o** ruta del ejecutable) | El patrón es correcto, pero solo para una app |
| `Participant.email` ya existe y es opcional | No se normaliza, no se deduplica ni se vincula a otras fuentes |
| Sin detección de llamadas ni calendario | La grabación es 100 % manual; "Próximas reuniones" no existe |

## 3. Hallazgos verificados en este Mac

| App | Bundle principal | Procesos que emiten audio (verificado) | Implicación para la captura |
|---|---|---|---|
| Microsoft Teams | `com.microsoft.teams2` | `com.microsoft.teams2.*` + `com.microsoft.edgewebview2.helper*` **dentro** de `Microsoft Teams.app` | Aislable (ya implementado) |
| Zoom | `us.zoom.xos` | auxiliares `us.zoom.*` (CptHost, caphost, aomhost, ZoomHybridConf…) | Aislable por prefijo y ruta |
| Google Chrome | `com.google.Chrome` | `com.google.Chrome.helper` (servicio de audio) | Captura **todas las pestañas** (Meet + YouTube…) |
| Microsoft Edge | `com.microsoft.edgemac` | `com.microsoft.edgemac.helper*` | Igual que Chrome; distinto del WebView2 de Teams |
| Safari | `com.apple.Safari` | `com.apple.WebKit.GPU` (**compartido** con cualquier app que use WebKit) | Hay que verificar a qué app atribuye el HAL ese proceso |
| FaceTime | sistema | daemon de conferencia del sistema (AVConference) | Hay que verificar en una llamada real qué proceso emite el audio |
| Drivers virtuales | — | `MSTeamsAudioDevice`, `ParrotAudioPlugin` | Ignorarlos como fuentes |

APIs confirmadas en el SDK: `kAudioProcessPropertyIsRunningInput` y `IsRunningOutput` (por proceso),
`EKEventStore.requestFullAccessToEvents` y `EKParticipant` (nombre y `mailto:`),
`AVAudioApplication.inputMuted` con su notificación de cambio, y `AXIsProcessTrustedWithOptions`.

## 4. Alcance propuesto (por fases)

### F1 · Catálogo de apps y captura generalizada — tamaño M
- **Catálogo declarativo `ConversationAppCatalog`**: identificador, nombre, prefijos de bundle, marcadores de ruta,
  tipo (`nativa`, `navegador`, `sistema`) y nivel de aislamiento (`exacto`, `compartido`).
- **Destino de captura:** `RemoteCaptureTarget.app(id)` / `.systemWide` / `.none`, más la migración v2: la reunión
  guarda la app de origen.
- **UI:** selector con las apps detectadas que usan audio. Los textos dejan de ser exclusivos de Teams. En navegadores
  aparece la advertencia "se captura el audio de todas las pestañas".
- **Aceptación:** pruebas de clasificación de procesos con los bundles reales de la tabla; grabación real de Zoom y Teams
  con captura limitada a cada app.

### F2 · Monitor de llamadas, sin permisos nuevos — tamaño M
- **Máquina de estados `CallMonitor`:** `inactiva → app abierta → llamada probable → terminada`.
  - Entradas: `NSWorkspace` (apertura y cierre de apps), avisos del HAL sobre procesos y entrada/salida de audio, y
    silencio en la pista remota.
  - **Llamada probable:** la misma app usa el micrófono **y** emite audio. **Fin:** libera el micrófono durante
    ≥ 25 s **y** la pista remota queda en silencio, o la app se cierra.
- **Avisos:** "Zoom está en una llamada — ¿Grabar?" y "Parece que la llamada terminó — Detener / Seguir".
  - **Nunca graba ni se detiene sola**, salvo que lo actives por app en Ajustes (requisito M).
- **"Pausar mi micrófono"** en la grabación, integrado con el silencio del sistema (`AVAudioApplication`). Los tramos en
  pausa quedan marcados.
- **Aceptación:** pruebas de la máquina de estados con trazas de eventos simuladas, incluido el cambio a AirPods sin
  falso fin de llamada; validación manual con una llamada real.

### F3 · Identidad, correo y calendario (opcional) — tamaño M
- **Participante:** el correo sigue siendo opcional, pero se normaliza. Un correo duplicado genera una sugerencia de
  fusión (reutiliza la fusión y separación ya existentes).
- **`CalendarService` (EventKit, permiso de Calendario, desactivado por defecto):**
  - busca el evento que coincide por horario y propone título e invitados como **candidatos** (nombre + correo);
  - muestra "Próximas reuniones" en Inicio.
- **Asignar identidad:** puedes elegir un participante existente o un invitado del evento; si eliges un invitado se crea
  el participante con su correo. Sigue sin haber asignación automática por calendario.
- **Exportación y MCP:** el correo solo se incluye si lo autorizas (`exposeEmails` ya existe).
- **Aceptación:** pruebas con un almacén de calendario simulado detrás de un protocolo; validación manual con tu
  calendario real.

### F4 · Experimento de Accessibility (opcional) — tamaño S, con decisión de seguir o descartar
- **Qué se intenta:** leer el estado del botón de silencio y la lista de participantes de Teams y Zoom, en modo de solo
  lectura.
- **Seguir solo si:**
  - no hay que forzar `AXManualAccessibility` (sería interferir con la app),
  - funciona en español y en inglés,
  - y sobrevive a reinicios de la app.
- **Si funciona:** se marcan (sin borrarlos) los segmentos del micrófono "dichos con la app silenciada" y se ofrece la
  lista como candidatos.
- **Si falla:** se descarta y se documenta en `TECHNICAL_DECISIONS.md`.

**Orden recomendado:** F1 → F2 → F3 → F4. F1 y F2 aportan el mayor valor sin pedir permisos nuevos.

## 5. Permisos e impacto en privacidad

| Permiso | Fase | ¿Obligatorio? | Uso |
|---|---|---|---|
| Micrófono / Grabación de audio del sistema | ya existen | sí | captura |
| Notificaciones | F2 | no (alternativa: indicador en la barra de menús) | avisos de inicio y fin |
| Calendario (acceso completo) | F3 | no | título, invitados, próximas reuniones |
| Accesibilidad | F4 | no (experimental) | estado de silencio y participantes |
| Grabación de pantalla | — | **no se pedirá** | (los títulos de ventana no compensan el permiso) |

## 6. Riesgos y mitigaciones

| Riesgo | Mitigación |
|---|---|
| Navegador: se mezclan pestañas (música, vídeos) | Advertencia visible; la detección por micrófono confirma que hay llamada; documentarlo |
| Safari/FaceTime comparten procesos del sistema | Verificar la atribución del HAL; si no es fiable, ofrecer solo "todo el sistema" con aviso |
| Falsos fines de llamada (cambio de dispositivo, espera) | Margen ≥ 25 s + doble señal; nunca se detiene sola sin configuración |
| La app mantiene el micrófono abierto en el lobby o en silencio | La sugerencia de grabar exige también audio remoto; la decisión final es tuya |
| Accessibility frágil o versionado | F4 aislada, opcional y con decisión de seguir o descartar |
| El calendario no contiene reuniones de Outlook nuevo | Es opcional; la app funciona igual sin él |

## 7. Cambios de datos (migración v2)

- `meeting.sourceAppId` y `meeting.sourceAppName`, y `CaptureScope.applicationProcesses`; los valores antiguos se
  migran desde `teamsProcesses`.
- `meeting.calendarEventId` (opcional) y una tabla `meetingInvitee` (nombre, correo, `participantId` opcional).
- `participant.emailNormalized` con índice único parcial.
- `recordingPause` (inicio, fin, motivo: usuario o silencio de la app).

## 8. Fuera de alcance

Bots, APIs en la nube de Zoom o Microsoft Graph (exigen un servidor o consentimiento de la organización), extensiones
de navegador, aislar una pestaña concreta e inyectar código en otras apps.

## 9. Verificación que depende de ti

- Llamadas reales en Teams, Zoom y Meet (Chrome), y en Safari y FaceTime, para confirmar qué proceso emite el audio.
- Comprobar si tus reuniones aparecen en la app Calendario de macOS.
- Conceder los permisos opcionales solo si apruebas las fases F2 a F4.

## 10. Decisiones que necesito de ti

1. Prioridad de plataformas (propuesta: Teams y Zoom → Meet en Chrome → Slack y Webex → Safari y FaceTime).
2. ¿Permitir el inicio automático de la grabación por app, o solo sugerencias?
3. ¿Incluir el calendario (F3)?
4. ¿Ejecutar el experimento de Accessibility (F4)?
