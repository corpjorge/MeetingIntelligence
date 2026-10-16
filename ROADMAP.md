# Roadmap

| Fase | Contenido | Estado |
|---|---|---|
| 0 | Entorno, investigación de FluidAudio/Taps/CLIs/MCP, arquitectura | ✅ |
| 1 | App compilable, navegación, Design System, persistencia | ✅ |
| 2 | Captura Teams (process tap) + micrófono, sincronía, recuperación | ✅ implementada · ⏳ prueba con llamada real |
| 3 | FluidAudio + Parakeet Ultra (definitiva) + provisional en vivo | ✅ verificada |
| 4 | Diarización offline + alineación + eco | ✅ verificada (fixtures) |
| 5 | Perfiles persistentes y reconocimiento calibrado | ✅ implementada · ⏳ validación con voces reales |
| 6 | Claude Code, Codex, Antigravity, Ollama | ✅ (Codex verificado end-to-end) |
| 7 | Análisis con evidencia, búsqueda FTS5, chat | ✅ |
| 8 | Servidor MCP local | ✅ verificado por stdio |
| 9 | Testing integral, rendimiento, pulido | 🔄 en curso |
| 10 | Cualquier app de videollamada (F1) + detección de llamadas y pausa de micrófono (F2) + esfuerzo de IA | ✅ implementada · ⏳ validación con llamadas reales |
| 11 | Calendario e identidad con correo (F3) | ⏸ pendiente de tu decisión |
| 12 | Experimento Accessibility (F4) | ⏸ pendiente de tu decisión |

## Próximas tareas (priorizadas)

1. **Validación con llamadas reales** (Teams, Zoom, Meet en Chrome, Safari, FaceTime): confirmar la detección de
   inicio/fin, qué procesos emiten el audio, niveles, sincronía mic/remoto, cambio a AirPods y recuperación.
2. **Firma estable** (identidad propia o Developer ID) para que macOS conserve los permisos entre compilaciones.
3. **Medición con grabaciones reales autorizadas** (WER/DER/identificación) y ajuste de `stepRatio` y del umbral de
   hablantes locales con datos medidos.
4. Búsqueda semántica local (embeddings) como complemento de FTS5.
5. Historial persistente del chat.
6. Integración opcional de calendario para "Próximas reuniones" (requiere permiso de Calendario; no implementado).
7. Vocabulario con *boosting* acústico de FluidAudio (CTC) para nombres propios, evaluando su comportamiento en español.
