"""
jarvis_tools.py — Ejecuta consultas via Hermes CLI con sesion persistente.

El dashboard envia texto en lenguaje natural. El tools server llama a
hermes chat -q --continue jarvis-dashboard, que interpreta, ejecuta tools,
y recuerda TODO el contexto entre mensajes.

Usar: python scripts/jarvis_tools.py
Puerto: 8646
"""

import json, os, subprocess, sys, re
from http.server import HTTPServer, BaseHTTPRequestHandler

HERMES_HOME = os.environ.get("HERMES_HOME", os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
HERMES_BIN = os.path.join(
    os.environ.get("LOCALAPPDATA", os.path.expanduser("~")),
    "hermes", "hermes-agent", "venv", "Scripts", "hermes.exe"
)


def query_jarvis(text: str) -> str:
    """Llama a hermes chat -q con sesion persistente. Retorna solo la respuesta."""
    try:
        r = subprocess.run(
            [HERMES_BIN, "chat", "-q", text, "--max-turns", "8"],
            capture_output=True, text=True, timeout=120,
            env={**os.environ, "HERMES_HOME": HERMES_HOME, "PYTHONIOENCODING": "utf-8"},
            cwd=HERMES_HOME,
            encoding="utf-8",
        )
        output = r.stdout
        # Estrategia: buscar la primera linea con texto real despues de "Query:"
        # y antes de "Resume this session with:"
        lines = output.split('\n')
        result_lines = []
        started = False
        for line in lines:
            # Saltar lineas de metadata
            if 'Query:' in line or 'Initializing' in line:
                continue
            if 'Resume this session' in line or 'Session:' in line or 'Duration:' in line or 'Messages:' in line:
                break
            # Limpiar ANSI y bordes
            clean = re.sub(r'\x1b\[[0-9;]*m', '', line).strip()
            clean = clean.strip('\u2500\u2550\u2502\u2551\u256d\u256e\u256f\u2570\u250c\u2510\u2514\u2518 ╭╮╰╯│─┌┐└┘⚕')
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

        text = payload.get("message", "")
        if not text:
            self.send_error(400, "missing message"); return

        reply = query_jarvis(text)

        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(json.dumps({"reply": reply}, ensure_ascii=False).encode())

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def log_message(self, format, *args):
        pass


if __name__ == "__main__":
    port = int(os.environ.get("TOOLS_PORT", "8646"))
    server = HTTPServer(("0.0.0.0", port), Handler)
    print(f"Jarvis Tools en http://0.0.0.0:{port}/ (hermes chat -q --continue jarvis-dashboard)")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nTools detenido.")
        server.server_close()
