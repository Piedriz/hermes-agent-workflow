"""
jarvis_tools.py — Ejecuta consultas via Hermes CLI con sesion persistente.

El dashboard envia texto en lenguaje natural. El tools server llama a
hermes chat -q con --resume para mantener la misma sesion.
Jarvis recuerda TODO el contexto entre mensajes.

Usar: python scripts/jarvis_tools.py
Puerto: 8646
"""

import json, os, re, subprocess
from http.server import HTTPServer, BaseHTTPRequestHandler

HERMES_HOME = os.environ.get("HERMES_HOME", os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
HERMES_BIN = os.path.join(
    os.environ.get("LOCALAPPDATA", os.path.expanduser("~")),
    "hermes", "hermes-agent", "venv", "Scripts", "hermes.exe"
)
VENV_PYTHON = os.path.join(
    os.environ.get("LOCALAPPDATA", os.path.expanduser("~")),
    "hermes", "hermes-agent", "venv", "Scripts", "python.exe"
)
SETUP_SCRIPT = os.path.join(HERMES_HOME, "skills", "productivity", "google-workspace", "scripts", "setup.py")
TOKEN_FILE = os.path.join(HERMES_HOME, "google_token.json")

SESSION_FILE = os.path.join(HERMES_HOME, ".jarvis_session_id")
SESSION_ID = None


def google_account() -> dict:
    """Verifica autenticacion y extrae email."""
    if not os.path.exists(TOKEN_FILE):
        return {"email": None, "authenticated": False}

    try:
        r = subprocess.run(
            [VENV_PYTHON, os.path.join(HERMES_HOME, "skills", "productivity", "google-workspace", "scripts", "google_api.py"),
             "gmail", "search", "is:unread", "--max", "1"],
            capture_output=True, text=True, timeout=20,
            env={**os.environ, "PYTHONIOENCODING": "utf-8", "HERMES_HOME": HERMES_HOME},
            cwd=HERMES_HOME,
        )
        if r.returncode != 0 or "error" in r.stdout.lower()[:100]:
            return {"email": None, "authenticated": False}

        # Extraer email de los resultados
        data = json.loads(r.stdout)
        if isinstance(data, list) and len(data) > 0:
            email_raw = data[0].get("to", "")
            # Limpiar formato "Name <email>"
            if "<" in email_raw:
                email = email_raw.split("<")[1].split(">")[0].strip()
            else:
                email = email_raw.strip()
            return {"email": email, "authenticated": True}

        # Si no hay correos, autenticado igual
        return {"email": "Gmail OK", "authenticated": True}

    except Exception as e:
        # Si el token existe pero la API falla, asumir no autenticado
        return {"email": None, "authenticated": False, "error": str(e)[:100]}


def google_logout() -> dict:
    """Revoca acceso Google y borra token."""
    try:
        r = subprocess.run(
            [VENV_PYTHON, SETUP_SCRIPT, "--revoke"],
            capture_output=True, text=True, timeout=30,
            env={**os.environ, "PYTHONIOENCODING": "utf-8", "HERMES_HOME": HERMES_HOME},
            cwd=HERMES_HOME,
        )
        return {"status": "ok", "output": r.stdout.strip()}
    except Exception as e:
        return {"status": "error", "message": str(e)}


def google_auth_url() -> dict:
    """Genera URL de autorizacion Google OAuth."""
    try:
        r = subprocess.run(
            [VENV_PYTHON, SETUP_SCRIPT, "--auth-url"],
            capture_output=True, text=True, timeout=30,
            env={**os.environ, "PYTHONIOENCODING": "utf-8", "HERMES_HOME": HERMES_HOME},
            cwd=HERMES_HOME,
        )
        url = r.stdout.strip()
        if url.startswith("http"):
            return {"url": url}
        return {"error": r.stdout.strip()}
    except Exception as e:
        return {"error": str(e)}


def google_auth_code(code: str) -> dict:
    """Intercambia codigo OAuth por token."""
    try:
        r = subprocess.run(
            [VENV_PYTHON, SETUP_SCRIPT, "--auth-code", code],
            capture_output=True, text=True, timeout=60,
            env={**os.environ, "PYTHONIOENCODING": "utf-8", "HERMES_HOME": HERMES_HOME},
            cwd=HERMES_HOME,
        )
        output = r.stdout.strip()
        if "OK" in output or "Authenticated" in output:
            return google_account()
        return {"error": output}
    except Exception as e:
        return {"error": str(e)}


def load_session():
    """Carga el ID de sesion guardado en disco."""
    global SESSION_ID
    if os.path.exists(SESSION_FILE):
        with open(SESSION_FILE) as f:
            sid = f.read().strip()
            if sid and len(sid) > 10:
                SESSION_ID = sid
                return


def save_session(sid):
    """Guarda el ID de sesion en disco (persiste entre reinicios)."""
    global SESSION_ID
    SESSION_ID = sid
    with open(SESSION_FILE, "w") as f:
        f.write(sid)


def query_jarvis(text: str) -> str:
    global SESSION_ID
    try:
        args = [HERMES_BIN, "chat", "-q", text, "--max-turns", "5"]
        if SESSION_ID:
            args += ["--resume", SESSION_ID]

        r = subprocess.run(
            args,
            capture_output=True, text=True, timeout=120,
            env={**os.environ, "HERMES_HOME": HERMES_HOME, "PYTHONIOENCODING": "utf-8"},
            cwd=HERMES_HOME, encoding="utf-8",
        )
        output = r.stdout

        # Capturar session ID para reusar (viene en el output "hermes --resume XXX")
        for line in output.split('\n'):
            if '--resume' in line:
                sid = line.split('--resume')[-1].strip()
                if sid and len(sid) > 10:
                    save_session(sid)
                    break

        # Extraer respuesta (texto despues de Query:, antes de metadatos)
        lines = output.split('\n')
        result_lines = []
        for line in lines:
            # Saltar metadata y tool calls
            if any(x in line for x in ['Query:', 'Initializing', 'Resume this session', 'Session:', 'Duration:', 'Messages:', 'Resumed session', '┊', '--resume']):
                continue
            clean = re.sub(r'\x1b\[[0-9;]*m', '', line).strip()
            clean = clean.strip('\u2500\u2550\u2502\u2551\u256d\u256e\u256f\u2570\u250c\u2510\u2514\u2518 ╭╮╰╯│─┌┐└┘⚕↻🐍💻📚🔎📖')
            if clean and len(clean) > 2 and 'Hermes' not in clean:
                result_lines.append(clean)
        result = ' '.join(result_lines).strip()
        # Remover emojis y caracteres no imprimibles (mantiene ASCII + acentos español)
        result = ''.join(c for c in result if ord(c) < 65536 and (ord(c) < 128 or c in 'áéíóúñÁÉÍÓÚÑüÜ'))
        return result if result else "(sin respuesta)"
    except subprocess.TimeoutExpired:
        return "(timeout)"
    except Exception as e:
        return f"(error: {e})"


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        try:
            payload = json.loads(body)
        except:
            self.send_error(400); return

        # Endpoint rapido de conectividad (sin LLM)
        if payload.get("action") == "ping":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(json.dumps({"status": "ok", "session": SESSION_ID or "pending"}).encode())
            return

        # Google Account endpoints
        if payload.get("action") == "account":
            result = google_account()
        elif payload.get("action") == "gmail_logout":
            result = google_logout()
        elif payload.get("action") == "gmail_auth":
            result = google_auth_url()
        elif payload.get("action") == "gmail_code":
            result = google_auth_code(payload.get("code", ""))
        else:
            # Chat normal via Hermes
            text = payload.get("message", "")
            if not text:
                self.send_error(400, "missing message"); return
            result = {"reply": query_jarvis(text), "session": SESSION_ID}

        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(json.dumps(result, ensure_ascii=False).encode())

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def log_message(self, format, *args):
        pass


if __name__ == "__main__":
    load_session()
    port = int(os.environ.get("TOOLS_PORT", "8646"))
    server = HTTPServer(("0.0.0.0", port), Handler)
    print(f"Jarvis Tools en :{port} | sesion: {SESSION_ID or '(nueva)'}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nTools detenido.")
        server.server_close()
