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

## Próximas tareas (priorizadas)

1. **Validación en vivo con Teams**: grabar una llamada real autorizada; revisar niveles, sincronía mic/remoto,
   cambios a AirPods y recuperación tras cerrar la app.
2. **Firma estable** (identidad propia o Developer ID) para que macOS conserve los permisos entre compilaciones.
3. **Medición con grabaciones reales autorizadas** (WER/DER/identificación) y ajuste de `stepRatio` y del umbral de
   hablantes locales con datos medidos.
4. Búsqueda semántica local (embeddings) como complemento de FTS5.
5. Historial persistente del chat.
6. Integración opcional de calendario para "Próximas reuniones" (requiere permiso de Calendario; no implementado).
7. Vocabulario con *boosting* acústico de FluidAudio (CTC) para nombres propios, evaluando su comportamiento en español.
