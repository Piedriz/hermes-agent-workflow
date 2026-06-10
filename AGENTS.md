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

### Correo (Gmail) — USA SOLO google-workspace, NUNCA himalaya
- **NO uses himalaya.** El token OAuth ya esta configurado en google_token.json.
- Define primero: `GAPI="python skills/productivity/google-workspace/scripts/google_api.py"`
- **"Revisa mis correos", "clasifica correos", "últimos emails"**:
  → `$GAPI gmail search "is:unread" --max 20`
- **"Busca correos de X"**:
  → `$GAPI gmail search "from:persona@correo.com" --max 10`
- **"Lee el correo ID"**:
  → `$GAPI gmail get MESSAGE_ID`
- **"Responde a este correo"**:
  → `$GAPI gmail reply MESSAGE_ID --body "texto de respuesta"`
- **"Envía un correo a X"**:
  → `$GAPI gmail send --to email --subject "asunto" --body "texto"`
- **Siempre confirma antes de enviar.** Muestra el borrador primero.

### Calendario — USA SOLO google-workspace
- Define: `GAPI="python skills/productivity/google-workspace/scripts/google_api.py"`
- **"¿Qué tengo hoy/mañana?"** → `$GAPI calendar list`
- **"Agenda reunion"** → `$GAPI calendar create --summary "titulo" --start ISO --end ISO`
- **Eliminar evento** → confirmar dos veces.

### Drive / Documentos
- Define: `GAPI="python skills/productivity/google-workspace/scripts/google_api.py"`
- **"Busca en Drive X"** → `$GAPI drive search "termino" --max 10`
- **"Sube archivo"** → `$GAPI drive upload /ruta/archivo.pdf`
- **"Crea carpeta"** → `$GAPI drive create-folder "nombre"`
- **Procesar archivos** → Descargar con `$GAPI drive download ID`, procesar, resumir.
- **NUNCA borres archivos sin confirmar.**

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
