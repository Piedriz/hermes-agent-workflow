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

SESSION_FILE = os.path.join(HERMES_HOME, ".jarvis_session_id")
SESSION_ID = None


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
            if any(x in line for x in ['Query:', 'Initializing', 'Resume this session', 'Session:', 'Duration:', 'Messages:', 'Resumed session', '┊']):
                continue
            clean = re.sub(r'\x1b\[[0-9;]*m', '', line).strip()
            clean = clean.strip('\u2500\u2550\u2502\u2551\u256d\u256e\u256f\u2570\u250c\u2510\u2514\u2518 ╭╮╰╯│─┌┐└┘⚕↻🐍💻📚🔎📖')
            if clean and len(clean) > 2 and 'Hermes' not in clean:
                result_lines.append(clean)
        result = ' '.join(result_lines).strip()
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

        text = payload.get("message", "")
        if not text:
            self.send_error(400, "missing message"); return

        reply = query_jarvis(text)

        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(json.dumps({"reply": reply, "session": SESSION_ID}, ensure_ascii=False).encode())

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
