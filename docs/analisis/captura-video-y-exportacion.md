# Captura de video de reuniones y exportación

Fecha: 28 de octubre de 2026. Documento de investigación previo a la implementación. La primera implementación y su evidencia actual están descritas en TD-34 de `TECHNICAL_DECISIONS.md`; las tablas siguientes conservan el diagnóstico inicial.

## Resultado de la investigación

Recomendación para esta app: **ScreenCaptureKit para capturar la ventana elegida, AVAssetWriter para guardar el video y el motor actual para capturar el audio**. Una línea temporal común sincroniza las tres pistas. La exportación genera un MP4 con imagen y conversación mezclada, o un archivo de audio, o la transcripción.

Es una recomendación de arquitectura basada en el código y las APIs de Apple, pendiente de validar con grabaciones reales. No se midieron todavía consumo, calidad visual ni sincronización de una sesión audiovisual.

Alcance confirmado por el usuario: la ventana de Teams, Zoom o Meet, incluido el contenido compartido **que se vea en esa ventana**. Si la aplicación abre la presentación en otra ventana, hace falta elegir esa ventana o cambiar explícitamente la fuente. La captura no obtiene los flujos originales ni las cámaras de todos los participantes por separado.

## Qué existe y qué falta

| Capacidad | Situación actual | Cambio necesario |
|---|---|---|
| Audio de la aplicación + micrófono | Dos WAV de 16 kHz, mono, sincronizados | Conservar este recorrido para transcripción y AEC |
| Solo audio | Implementado, con selección de aplicación | Mantenerlo como modo predeterminado |
| Video | No existe un motor de grabación de video | Añadir fuente, escritor, metadatos y reproductor |
| Exportar transcripción | TXT, Markdown, JSON, SRT, PDF | Presentarlo claramente en el menú de exportación |
| Exportar audio | Se puede localizar la carpeta en Finder; no hay mezcla/exportador | Generar M4A o WAV y permitir pistas separadas |
| Exportar video | No existe | Combinar video y audio con la misma línea temporal |
| Importar MP4/MOV | Extrae audio; no conserva el video como recurso reproducible | Si se amplía la importación, conservar también el original |

Referencias del repositorio:

- `Sources/MeetingAudio/Capture/RecordingSession.swift`: ciclo de vida, fuentes separadas y AEC.
- `Sources/MeetingAudio/Capture/TrackRecorder.swift`: `CaptureClock`, pausas y alineación.
- `Sources/MeetingIntelligenceApp/Services/RecordingController.swift`: coordinación de grabación y finalización.
- `Sources/MeetingIntelligenceApp/Features/Recording/RecordingView.swift`: controles de grabación.
- `Sources/MeetingSpeech/Pipeline/MeetingImportService.swift`: registro de pistas e importación de contenedores.
- `Sources/MeetingCore/Export/MeetingExport.swift`: formatos de exportación actuales.
- `Sources/MeetingIntelligenceApp/Features/MeetingDetail/MeetingDetailView.swift`: menú Exportar y panel de guardado.
- `Sources/MeetingIntelligenceApp/App/AppEnvironment.swift`: retención actual, que solo elimina pistas de audio.
- `Sources/MeetingCore/Storage/StorageMaintenance.swift`: borrado de toda la carpeta de una reunión.

## Comparación de alternativas

| Alternativa | Ventajas | Límites para esta app | Decisión |
|---|---|---|---|
| ScreenCaptureKit + SCRecordingOutput | Grabación directa a archivo, menos código; disponible desde macOS 15 | No expone una pausa de grabación equivalente a `CaptureClock`; el audio que incorpora procede del propio stream; el SDK indica que cambiar la configuración del stream detiene su grabación | Útil como referencia/prototipo sencillo, no como motor elegido inicialmente |
| ScreenCaptureKit + AVAssetWriter + audio existente | Control de timestamps, pausas, codificación y fragmentos; conserva las pistas y AEC actuales | Más trabajo en coordinación, finalización y recuperación | **Recomendado para el producto** |
| Migrar también todo el audio a ScreenCaptureKit | Un stream puede entregar pantalla, audio y micrófono | Cambia un recorrido de audio importante; hay que reproducir AEC, cambios de dispositivo, resiliencia y atribución por fuente | Evaluar solo si el prototipo demuestra una ventaja concreta |
| Grabaciones periódicas de pantalla o captura legacy | Prueba conceptual sencilla | Copias y temporización menos adecuadas para video sostenido | Descartar para producción |
| Dependencia de grabación nativa de Teams/Zoom/Meet | Podría acceder al registro ofrecido por cada plataforma | No es una solución uniforme local para cualquier llamada; depende de cuenta, políticas y proveedor | Fuera del alcance |

Apple documenta ScreenCaptureKit como su recorrido de captura de ventanas, aplicaciones y pantallas, con buffers respaldados por GPU y escalado acelerado. La elección de AVAssetWriter sobre SCRecordingOutput es una decisión específica de esta app, por sus requisitos de pausa, AEC y recuperación; no significa que la API directa sea inadecuada en general. [S1, S3, S4]

## Experiencia propuesta

Antes de iniciar:

1. `Modo: Solo audio | Audio y video`.
2. Selección actual de la aplicación de audio y opción de micrófono.
3. En modo video, botón `Elegir ventana…` con el selector del sistema y previsualización de la fuente confirmada.
4. Mostrar aplicación de audio y ventana de video por separado; avisar si corresponden a aplicaciones distintas.
5. Calidad predeterminada equilibrada y una opción de mayor resolución para presentaciones con texto.
6. `Iniciar grabación` comienza la sesión; cancelar el selector no inicia una grabación parcial.

Solo audio no abre el selector de pantalla ni solicita acceso visual. Video usa el flujo de autorización de ScreenCaptureKit y el selector nativo, respetando el alcance que el sistema conceda; hay que probar la experiencia concreta en cada macOS soportado. No se debe afirmar que siempre requiere acceso global permanente a todas las pantallas. [S2]

Durante la grabación: indicador `Audio` o `Audio y video`, duración única, estado de la imagen, niveles de audio, pausa total y pausa exclusiva del micrófono. Cambiar la fuente de video requiere una selección explícita; nunca se amplía automáticamente a toda la pantalla.

En el detalle: pestaña de reproducción que muestra video si existe y audio en los demás casos. Una cita de transcripción/chat mueve el reproductor a su timestamp. El nombre actual «Audio» podría pasar a «Grabación».

Menú Exportar:

| Opción | Archivo propuesto | Disponibilidad |
|---|---|---|
| Audio de la reunión | M4A, conversación mezclada | Cuando los archivos de audio estén disponibles |
| Audio sin compresión adicional | WAV, mezcla | Igual; conserva la resolución de la fuente, no la mejora |
| Pistas de audio separadas | Carpeta/paquete con micrófono y remoto | Para edición o diagnóstico |
| Video con audio | MP4, H.264 + AAC | Cuando haya imagen grabada y finalizada |
| Transcripción | TXT, Markdown, PDF, SRT, JSON | Según los datos disponibles; avisar si el procesamiento está incompleto |

«Grabación» se interpreta aquí como el audio de la reunión; video significa imagen más audio. Subtítulos SRT separados en la primera versión. Incrustarlos en la imagen exigiría renderizar de nuevo y puede ser una ampliación posterior.

Audio/video pueden exportarse al finalizar los archivos, sin esperar a la IA ni a la transcripción. El exportador debe tener progreso y cancelación. Escribe primero un archivo temporal junto al destino y solo publica el resultado completo; no deja un MP4 aparentemente válido tras un fallo.

## Diseño de captura y sincronización

```text
Ventana elegida ── ScreenCaptureKit ── VideoRecorder / AVAssetWriter ── video.mov
                                                   ▲
                                     línea temporal común
                                                   ▼
Aplicación ── ProcessTapSource ── WAV remoto      CaptureClock
Micrófono ── AVAudioEngine ── AEC ── WAV local

video.mov + WAV alineados ── MediaExporter ── MP4 con audio / M4A / WAV
WAV alineados ── pipeline actual ── transcripción ── exportador documental
```

En este diseño ScreenCaptureKit captura **solo video**: `capturesAudio = false` y `captureMicrophone = false`. Evita duplicar micrófono y audio remoto, y permite que el audio del video exportado use el mismo tratamiento de eco que la grabación actual.

La sincronización no debe basarse en el instante en que se pulsa Iniciar ni en cuándo llega el callback. Hay que convertir los PTS del video desde el reloj del stream al reloj de host, y mapearlos al origen y las pausas de la sesión. `SCStream.synchronizationClock` y `CMSyncConvertTime` están disponibles en el SDK. [S6]

El `CaptureClock` actual ofrece un origen y un total de pausa, pero **el video necesita además un mapa histórico de intervalos**: un frame encolado antes de una pausa puede llegar después de reanudarla. Su posición debe calcularse con las pausas anteriores a su timestamp, no con el total de pausas cuando se procesa el callback. Conservar timestamps monotónicos, descartar frames pertenecientes a pausas y probar buffers tardíos y fuera de orden.

- Pausa total: omitir audio e imagen del intervalo, manteniendo el mismo corte temporal.
- Pausa del micrófono: silencio en su pista, mientras remoto y video continúan.
- Primer frame tardío: guardar el offset real; representar el tramo inicial sin imagen, sin adelantar el video.
- Pantalla estática: los frames pueden ser esporádicos. Conservar la duración de la imagen y asegurar el cierre del tramo final; no confundir ausencia de cambios con pérdida de captura.
- Fuente no disponible: registrar un intervalo sin video y mostrarlo como tal al reproducir/exportar. El audio continúa y la UI avisa. Si la fuente falla al iniciar, no presentar la sesión como «Audio y video» activa.
- Finalización: esperar a los escritores y persistir los estados antes de habilitar la exportación. Un fallo de video no debe descartar WAV ya grabados.

La cola del escritor de video debe estar separada de la cola compartida de audio/AEC. Cola de frames limitada, liberación rápida de superficies y descarte controlado ante saturación. Reducir o perder frames debe quedar registrado, sin bloquear el audio. [S3]

## Calidad, tamaño y resistencia a fallos

Perfil inicial propuesto: SDR, H.264, hasta 1080p y 30 fps, conservando proporciones y sin ampliar fuentes pequeñas. Mantener un lienzo de codificación estable aunque cambie el tamaño de la ventana. Ofrecer mayor resolución/original para texto fino; validar legibilidad con código, tablas y diapositivas reales. HDR, 4K por defecto y 60 fps no son necesarios para la primera versión.

El bitrate definitivo se decide con mediciones. Como presupuesto, **4–8 Mbit/s** de video equivale a **1,8–3,6 GB/h decimales**, antes de audio, contenedor y temporales: `bitrate × 3.600 ÷ 8`. No es una medición ni una promesa de tamaño. Exportar puede necesitar temporalmente espacio adicional para el archivo completo.

El audio actual de 16 kHz mono está orientado a voz y ASR. Exportarlo a AAC o remuestrearlo a 48 kHz no recupera fidelidad perdida. Si el producto exige audio de archivo con música/sonido de alta fidelidad, hace falta añadir una pista maestra a mayor frecuencia y derivar de ella el audio de análisis. Esto merece un cambio independiente: no alterar el AEC actual sin medirlo.

Para almacenamiento de video, usar un contenedor fragmentado compatible mediante `movieFragmentInterval`; comenzar probando MOV con fragmentos de 10 segundos. Apple documenta reproducción parcial tras interrupción para formatos compatibles, pero **no garantiza aquí el resultado de nuestra combinación de codec, disco y escritor**. Validar cierre forzado, legibilidad del archivo y pérdida máxima antes de fijar una garantía de recuperación. La exportación de usuario sigue siendo MP4 convencional. [S5]

Evitar mantener simultáneamente un MP4 definitivo y una copia maestra idéntica solo por conveniencia: generar el exportado bajo demanda, con caché acotada si resulta útil.

## Casos que determinan si la función es confiable

- Una ventana tapada puede seguir capturándose; minimizarla es distinto: Apple documenta suspensión del video hasta restaurarla. Confirmar el comportamiento en los sistemas soportados. [S3]
- Una ventana individual no incluye automáticamente otras ventanas, emergentes o una presentación separada. No prometer captura de «toda la reunión» cuando cambie la ventana visible. [S3]
- Meet en Chrome/Edge/Safari: elegir una ventana de video no aísla automáticamente una pestaña de audio. El recorrido actual puede recoger otros sonidos del navegador. Avisarlo y recomendar una ventana de reunión dedicada, sin afirmar que eso aísla el audio.
- La captura refleja lo que la app dibuja: pestañas distintas, chats visibles y cambios de diseño pueden modificar el contenido grabado. No hay extracción de cámaras ni de pantalla compartida original.
- Distinguir frame estático, minimización, cierre de ventana, bloqueo del Mac, reposo, retirada de autorización y contenido no capturable. Los callbacks más nuevos, como actividad/inactividad de macOS 15.2, necesitan disponibilidad y alternativa en 15.0.
- Probar compartir pantalla desde la propia app de llamada mientras esta app graba: rendimiento conjunto y ventanas nuevas son riesgos reales.
- Todos los archivos quedan locales. Grabar video no amplía lo que se envía al proveedor de IA; cualquier futura comprensión visual necesita su propio diseño y acción explícita.

## Integración por módulos

1. Nuevo módulo `MeetingMedia` para video, mezcla, mux y lectura audiovisual, dependiente de `MeetingCore`; mantener `MeetingAudio` centrado en audio. Extraer el reloj y el mapa de pausas a una pieza compartida independiente del HAL, o definir un contrato común antes de conectar ambos motores.
2. Coordinador de sesión en la app que gobierne audio y video. Estados separados para grabación, finalización y errores de cada medio.
3. Nueva migración: recurso `VideoAsset` y sus intervalos/segmentos, con ruta relativa, codec, dimensiones, duración, offset, tamaño y estado de finalización. No meter video dentro de `AudioTrack`, ni confundir modo de grabación con `CaptureScope`, que hoy describe el audio.
4. Guardar todos los medios bajo `Recordings/<meetingId>/`. El borrado completo ya recorre esa carpeta; añadir referencias y comprobar cascadas.
5. Diseñar explícitamente retención de medios: la rutina actual solo elimina archivos de `AudioTrack`. No permitir que sobrevivan videos indefinidamente ni eliminar video nuevo mediante una preferencia antigua cuyo texto dice «audio» sin revisar su significado.
6. Exportador multimedia async con mezcla de fuentes a ganancia controlada, manejo de clipping, offsets y pausas; no concatenar WAV ni sumar a volumen completo sin control.
7. Reproductor común que sincronice video, audio y saltos por cita. Las pistas fuente se conservan para reprocesar.
8. Importación de videos existentes como ampliación posterior: conservar el original antes de extraer el audio. La implementación actual solo registra el audio extraído.

## Validación antes de implementar la experiencia completa

La primera entrega técnica debe ser un prototipo acotado, sin modificar las grabaciones existentes. Comparar SCRecordingOutput con la ruta recomendada al menos en una sesión simple para verificar que la complejidad adicional se justifica.

| Prueba | Criterio propuesto; aún sin medir |
|---|---|
| Sesión audiovisual de 60 minutos | Desfase A/V absoluto ≤ 80 ms al inicio, mitad y final, medido con estímulos visuales/sonoros conocidos |
| Pausar/reanudar repetidamente | Mismo corte en las pistas; timestamps monotónicos; sin deriva acumulada |
| Pausar solo el micrófono | Silencio local sin cortar remoto ni imagen |
| Cambiar tamaño, pantalla y escala Retina | Sin deformación, reproducción/exportación válidas y texto legible |
| Cubrir, minimizar, restaurar y cerrar la fuente | Estados correctos, audio conservado y ningún salto silencioso a otra fuente |
| Meet y otras pestañas con audio | Alcance real documentado y aviso correcto |
| Llamada con auriculares/altavoces y cambio de dispositivo | Comportamiento de eco y continuidad no peores que la línea base de audio |
| Cierre forzado y recuperación | Archivo parcial reproducible; pérdida medida frente al intervalo configurado |
| Disco lleno y exportación cancelada | Error visible; originales preservados; sin archivo final engañoso |
| Audio/video exportados y SRT | Duración y timestamps coherentes; conversación completa sin saturación |
| CPU/GPU/RAM y batería | Comparación con solo audio, memoria acotada y sin pérdida de buffers de audio |
| macOS 15 y versión actual del equipo | Autorización, inicio/fin, reproducción y exportación comprobados por separado |

Orden de trabajo recomendado: (1) prototipo de captura/sincronización/recuperación; (2) exportación de audio y reorganización del menú existente; (3) integrar modo de video, persistencia y reproducción; (4) exportación MP4 y pruebas de larga duración. El éxito del prototipo habilita la implementación; no basta con generar unos segundos de video reproducible.

## Evidencia obtenida y límites

- Inspección del código, arquitectura y decisiones técnicas actuales, sin cambiar código productivo en esta investigación.
- Consulta de documentación oficial de Apple y cabeceras del SDK macOS 26.5 usado por el proyecto.
- Comprobación de tipos Swift 6 con destino `arm64-apple-macosx15.0`: selector de ventana, configuración SDR/30 fps, reloj de sincronización, AVAssetWriter con fragmentos y configuración de SCRecordingOutput. Resultado: sin errores.
- El archivo de comprobación acompaña este informe: `VideoAPICheck.swift`. Solo comprueba APIs; no ejecuta captura ni demuestra rendimiento, disponibilidad de hardware o corrección de sincronización.
- No se iniciaron grabaciones de pantalla, cámara ni reuniones durante esta investigación. La captura física y AEC existentes también tienen validaciones reales pendientes en TD-33.

Comando reproducible desde el directorio del proyecto:

```sh
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  xcrun swiftc -typecheck -swift-version 6 -target arm64-apple-macosx15.0 \
  -module-cache-path /private/tmp/mi-video-api-cache \
  docs/analisis/VideoAPICheck.swift
```

## Fuentes primarias

- [S1 · Apple: Capturing screen content in macOS](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos).
- [S2 · Apple: SCContentSharingPicker](https://developer.apple.com/documentation/screencapturekit/sccontentsharingpicker) y [WWDC23: What’s new in ScreenCaptureKit](https://developer.apple.com/videos/play/wwdc2023/10136/).
- [S3 · Apple: Take ScreenCaptureKit to the next level](https://developer.apple.com/videos/play/wwdc2022/10155/), especialmente comportamiento de ventana única y temporización.
- [S4 · Apple: Capture HDR content with ScreenCaptureKit](https://developer.apple.com/videos/play/wwdc2024/10088/), sección de grabación directa a archivo.
- [S5 · Apple: AVAssetWriter.movieFragmentInterval](https://developer.apple.com/documentation/avfoundation/avassetwriter/moviefragmentinterval); detalle contrastado con `AVFoundation.framework/Headers/AVAssetWriter.h` del SDK local.
- [S6 · Apple: SCStream.synchronizationClock](https://developer.apple.com/documentation/screencapturekit/scstream/synchronizationclock); contrastado con `ScreenCaptureKit.framework/Headers/SCStream.h`.
- Cabeceras locales `SCRecordingOutput.h` y `SCStream.h`: disponibilidad desde macOS 15, configuración de grabación, adición/retirada del escritor y efecto de actualizar la configuración durante la grabación.
