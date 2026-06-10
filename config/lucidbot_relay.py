"""
lucidbot_relay.py — Recibe webhooks de Lucidbot → Jarvis.

Dos modos automaticos:
  - API:   Usa la API OpenAI-compatible de Hermes (http://127.0.0.1:8642)
  - CLI:   Usa hermes chat -q (fallback si API no disponible)

Ejecutar: python scripts/lucidbot_relay.py
Lucidbot:  POST http://TU_IP:8645/
"""

import json, os, subprocess, time
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError

HERMES_API = os.environ.get("HERMES_API_URL", "http://127.0.0.1:8642/v1/chat/completions")
API_KEY = os.environ.get("API_SERVER_KEY", "jarvis-api-key-secreto")
MODEL = os.environ.get("LLM_MODEL", "grok-4")
HERMES_HOME = os.environ.get("HERMES_HOME", os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
HERMES_BIN = os.environ.get("HERMES_BIN", os.path.join(
    os.environ.get("LOCALAPPDATA", os.path.expanduser("~")),
    "hermes", "hermes-agent", "venv", "Scripts", "hermes.exe"
))
LISTEN_HOST = os.environ.get("RELAY_HOST", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("RELAY_PORT", "8645"))


def build_prompt(payload: dict) -> str:
    phone = payload.get("phone", "desconocido")
    first = payload.get("first_name", "")
    last = payload.get("last_name", "")
    name = f"{first} {last}".strip() or "Usuario"
    message = payload.get("message", "")

    return (
        f"Recibiste un mensaje de WhatsApp via Lucidbot.\n"
        f"De: {name} ({phone})\n"
        f"Mensaje: \"{message}\"\n\n"
        f"Responde en espanol. Se conciso. "
        f"Para responder al WhatsApp usa: "
        f"python scripts/lucidbot_send.py --phone \"{phone}\" --name \"{name}\" --message \"TU_TEXTO\""
    )


def try_api(prompt: str) -> str | None:
    """Intenta usar la API HTTP de Hermes."""
    body = json.dumps({
        "model": MODEL,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": 500,
    }).encode("utf-8")

    req = Request(HERMES_API, data=body, method="POST")
    req.add_header("Authorization", f"Bearer {API_KEY}")
    req.add_header("Content-Type", "application/json")

    try:
        with urlopen(req, timeout=15) as resp:
            result = json.loads(resp.read())
            if "choices" in result:
                return result["choices"][0]["message"]["content"]
    except Exception:
        pass
    return None


def try_cli(prompt: str) -> str:
    """Fallback: usa hermes chat -q via subprocess."""
    try:
        result = subprocess.run(
            [HERMES_BIN, "chat", "-q", prompt, "--max-turns", "3"],
            capture_output=True, text=True, timeout=120,
            env={**os.environ, "HERMES_HOME": HERMES_HOME},
        )
        if result.returncode != 0:
            return f"Error del agente: {result.stderr[:300]}"
        return result.stdout.strip() or "(sin texto)"
    except subprocess.TimeoutExpired:
        return "(timeout - el agente tardo demasiado)"
    except FileNotFoundError:
        return "(hermes.exe no encontrado en " + HERMES_BIN + ")"


class RelayHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)

        try:
            payload = json.loads(body)
        except json.JSONDecodeError:
            self.send_error(400, "invalid json")
            return

        name = f"{payload.get('first_name','')} {payload.get('last_name','')}".strip()
        msg_preview = payload.get("message", "")[:80]
        print(f"[{time.strftime('%H:%M:%S')}] {name} ({payload.get('phone','?')}): {msg_preview}", flush=True)

        prompt = build_prompt(payload)

        reply = try_api(prompt)
        mode = "API"
        if reply is None:
            reply = try_cli(prompt)
            mode = "CLI"

        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.end_headers()
        self.wfile.write(json.dumps({
            "reply": reply,
            "mode": mode,
        }, ensure_ascii=False).encode("utf-8"))

    def log_message(self, format, *args):
        pass


if __name__ == "__main__":
    server = HTTPServer((LISTEN_HOST, LISTEN_PORT), RelayHandler)
    print(f"Lucidbot Relay: http://{LISTEN_HOST}:{LISTEN_PORT}/")
    print(f"API: {HERMES_API}  (fallback: hermes chat -q)")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nRelay detenido.")
        server.server_close()
