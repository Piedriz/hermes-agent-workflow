# AGENTS.md — Tool Routing Hints for Jarvis

Este archivo se carga en cada sesión. Indica qué herramientas usar
según el tipo de solicitud.

## Tool Selection — por tipo de solicitud

### Calendario / Scheduling
- **"¿Qué tengo en el calendario?", "¿tengo reuniones mañana?"**
  → `google-workspace` skill → `calendar list --max 10`
- **"Agenda una reunión", "crea un evento"**
  → `google-workspace calendar create` — pedir confirmación antes.
- **Eliminar/mover eventos** → confirmar dos veces.

### Correo (Gmail)
- Usa el skill `google-workspace` para Gmail.
- Cuenta principal: la configurada en `gog`.
- **Siempre borrador primero.** Default: `drafts create`.
  Solo `send` cuando el usuario diga "envíalo", "mándalo", "dale".
- **"Revisa mi correo", "¿tengo correos sin responder?"**
  → `gog gmail messages list --max 20 --filter "is:unread"`
- **"Clasifica mis correos"**
  → Lee los no leídos, clasifica por importancia (urgente, importante,
    baja prioridad), presenta resumen.

### Drive / Documentos
- **"Busca en Drive", "revisa la carpeta X"**
  → `google-workspace` skill → `drive list --folder "nombre"`
- **Procesar archivos** → Extraer, resumir, proponer acciones.
- **Mover archivos entre carpetas** → confirmar antes.

### WhatsApp (vía Lucidbot)
- Los mensajes de WhatsApp llegan a través de Lucidbot vía webhook.
- Para responder: el webhook de Lucidbot se encarga del envío.
- **"Responde a X por WhatsApp"** → usa el endpoint de Lucidbot.

### Memoria (hindsight)
- Usa `recall` para buscar contexto de conversaciones pasadas.
- `MEMORY.md` y `USER.md` en `memories/` se cargan por sesión.
- Actualiza `USER.md` cuando aprendas preferencias nuevas del usuario.
- Actualiza `MEMORY.md` cuando aprendas sobre el entorno o flujos.

### Búsqueda web
- `web_search` para búsquedas rápidas, verificación de datos.
- Para investigación profunda, usa el skill `research`.

### Terminal / Código
- `terminal` para comandos shell.
- `python_runner` para scripts Python ad-hoc.
- Trabajos largos van con `background=true`.

### Voz
- El usuario interactúa por voz diciendo "Hola Jarvis".
- Transcripción vía OpenAI Whisper (STT).
- Respuestas concisas para voz (1-3 frases).

## Reglas de enrutamiento

- **Idioma default: Español.** Si el usuario escribe en inglés,
  responde en inglés.
- **"Revisa mi día"** → calendario + correos no leídos + recordatorios.
- **"Responde a [persona]"** → busca el contacto, pregunta qué
  plataforma usar (Gmail, WhatsApp/Lucidbot).
- **Cuando dudes entre dos opciones, PREGUNTA.** No asumas.

## Self-update

Si durante una sesión descubres un mejor patrón para invocar una
herramienta, actualiza la sección relevante de este archivo al final
de la sesión. Edita la línea existente, no agregues comentarios "NOTE:".
