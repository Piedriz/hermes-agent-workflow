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

### Correo (Gmail) — USA execute_code con ruta venv Python
- **NO uses himalaya.** El token OAuth esta en google_token.json.
- **Python venv:** `C:\Users\DELL\AppData\Local\hermes\hermes-agent\venv\Scripts\python.exe`
- **Usa execute_code con este patron** para Gmail:
  ```python
  import subprocess, os
  os.chdir(os.environ['HERMES_HOME'])
  PY = r'C:\Users\DELL\AppData\Local\hermes\hermes-agent\venv\Scripts\python.exe'
  r = subprocess.run([PY, 'skills/productivity/google-workspace/scripts/google_api.py',
       'gmail', 'search', 'is:unread', '--max', '20'],
      capture_output=True, text=True, env={**os.environ, 'PYTHONIOENCODING': 'utf-8'})
  print(r.stdout[:2000] if r.returncode == 0 else r.stderr[:500])
  ```
- **"Clasifica correos"**: mismo patron, evalua el JSON de salida
- **"Lee correo ID"**: `['gmail', 'get', MESSAGE_ID]`
- **"Responde"**: `['gmail', 'reply', ID, '--body', 'texto']`
- **"Envía"**: `['gmail', 'send', '--to', email, '--subject', asunto, '--body', texto]`
- **Siempre confirma antes de enviar.**

### Calendario — Usa execute_code
- Mismo patron que Gmail, cambia `'gmail'` por `'calendar'`:
  ```python
  import subprocess, os
  os.chdir(os.environ['HERMES_HOME'])
  r = subprocess.run(
      ['python', 'skills/productivity/google-workspace/scripts/google_api.py',
       'calendar', 'list'], capture_output=True, text=True,
      env={**os.environ, 'PYTHONIOENCODING': 'utf-8'})
  print(r.stdout[:2000] if r.returncode == 0 else r.stderr[:500])
  ```
- **"Agenda reunion"**: `['calendar', 'create', '--summary', titulo, '--start', ISO, '--end', ISO]`
- **Eliminar**: confirmar dos veces.

### Drive — Usa execute_code
- **"Busca en Drive"**: `['drive', 'search', termino, '--max', '10']`
- **"Descarga archivo"**: `['drive', 'download', FILE_ID]`
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
