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
- Usa `scripts/gapi` (wrapper de google_api.py). Si falla, usa execute_code.
- **"Revisa correos"**: `scripts/gapi gmail search "is:unread" --max 20`
- **"Busca correos de X"**: `scripts/gapi gmail search "from:persona@correo.com"`
- **"Lee correo ID"**: `scripts/gapi gmail get ID`
- **"Responde"**: `scripts/gapi gmail reply ID --body "texto"`
- **"Envía correo"**: `scripts/gapi gmail send --to email --subject "asunto" --body "texto"`
- **Siempre confirma antes de enviar.** Himalaya está deshabilitado.

### Calendario
- **"¿Qué tengo hoy?"**: `scripts/gapi calendar list`
- **"Agenda reunión"**: `scripts/gapi calendar create --summary "título" --start ISO --end ISO`
- **Eliminar**: doble confirmación.

### Drive
- **"Busca en Drive"**: `scripts/gapi drive search "término"`
- **"Descarga archivo"**: `scripts/gapi drive download ID`
- **NUNCA borres sin confirmar.**

### WhatsApp (vía Lucidbot)
- Los mensajes de WhatsApp llegan via API de Lucidbot → Hermes `/v1/chat/completions`.
- El mensaje ya viene formateado como prompt en `messages[0].content`.
- Para enviar mensajes **proactivos** a WhatsApp (recordatorios, alertas):
  ```
  python scripts/lucidbot_send.py --phone "+57300..." --name "Nombre" --message "texto"
  ```
- El script usa `LUCIDBOT_ACCESS_TOKEN` del .env.
- **NUNCA** envíes sin confirmar con el usuario.

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
