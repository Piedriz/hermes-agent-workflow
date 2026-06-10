"""
lucidbot_relay.py — Recibe webhooks de Lucidbot y los pasa a Jarvis.

Sin dependencias de HMAC ni templates. Directo al agente.

Ejecutar:
  python scripts/lucidbot_relay.py

Lucidbot debe apuntar a: http://TU_IP:8645/
"""

import json, os, subprocess, sys, time
from http.server import HTTPServer, BaseHTTPRequestHandler

LISTEN_HOST = os.environ.get("RELAY_HOST", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("RELAY_PORT", "8645"))
HERMES_HOME = os.environ.get("HERMES_HOME", os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
HERMES_BIN = os.environ.get("HERMES_BIN", "hermes")


def process_message(payload: dict) -> str:
    phone = payload.get("phone", "desconocido")
    first = payload.get("first_name", "")
    last = payload.get("last_name", "")
    name = f"{first} {last}".strip() or "Usuario"
    message = payload.get("message", "")

    prompt = (
        f"Recibiste un mensaje de WhatsApp via Lucidbot.\n"
        f"De: {name} ({phone})\n"
        f"Mensaje: \"{message}\"\n\n"
        f"Responde en espanol. Se conciso y profesional. "
        f"Si necesitas enviar respuesta, usa: "
        f"python scripts/lucidbot_send.py --phone \"{phone}\" --name \"{name}\" --message \"TU_TEXTO\""
    )

    try:
        result = subprocess.run(
            [HERMES_BIN, "chat", "-q", prompt, "--max-turns", "5"],
            capture_output=True, text=True, timeout=120,
            env={**os.environ, "HERMES_HOME": HERMES_HOME},
        )
        if result.returncode != 0:
            return f"Error: {result.stderr[:500]}"
        return result.stdout.strip() or "Ok (sin texto de respuesta)"
    except subprocess.TimeoutExpired:
        return "Timeout: el agente tardo demasiado."
    except FileNotFoundError:
        return f"Error: no se encontro el binario '{HERMES_BIN}'"


class RelayHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length)

        try:
            payload = json.loads(body)
        except json.JSONDecodeError:
            self.send_response(400)
            self.end_headers()
            self.wfile.write(b'{"error":"invalid json"}')
            return

        print(f"[{time.strftime('%H:%M:%S')}] Mensaje de {payload.get('first_name','?')} {payload.get('last_name','')}: {payload.get('message','')[:80]}", flush=True)

        response = process_message(payload)

        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.end_headers()
        self.wfile.write(json.dumps({
            "status": "ok",
            "response": response[:500],
        }, ensure_ascii=False).encode("utf-8"))

    def log_message(self, format, *args):
        pass


if __name__ == "__main__":
    server = HTTPServer((LISTEN_HOST, LISTEN_PORT), RelayHandler)
    print(f"Lucidbot Relay: http://{LISTEN_HOST}:{LISTEN_PORT}/")
    print(f"Hermes: {HERMES_BIN}  HOME: {HERMES_HOME}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nRelay detenido.")
        server.server_close()
