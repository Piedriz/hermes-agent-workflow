"""
jarvis_tools.py — HTTP endpoint para ejecutar herramientas directamente.

Sin LLM, sin approvals, sin Grok. Corre google_api.py en subprocess.
El dashboard lo llama para Gmail/Calendar/Drive.

Usar: python scripts/jarvis_tools.py
Puerto: 8646
"""

import json, os, subprocess, sys, io, wave, tempfile
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.request import Request, urlopen

HERMES_HOME = os.environ.get("HERMES_HOME", os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
VENV_PYTHON = os.path.join(
    os.environ.get("LOCALAPPDATA", os.path.expanduser("~")),
    "hermes", "hermes-agent", "venv", "Scripts", "python.exe"
)
API_SCRIPT = os.path.join(HERMES_HOME, "skills", "productivity", "google-workspace", "scripts", "google_api.py")
API_URL = os.environ.get("HERMES_API_URL", "http://127.0.0.1:8642/v1/chat/completions")
API_KEY = os.environ.get("API_SERVER_KEY", "jarvis-api-key-secreto")

def load_env_key(var_name):
    env_file = os.path.join(HERMES_HOME, ".env")
    try:
        with open(env_file) as f:
            for line in f:
                if line.startswith(f"{var_name}="):
                    return line.split("=", 1)[1].strip().strip("\"'")
    except: pass
    return os.environ.get(var_name, "")

OPENAI_KEY = load_env_key("VOICE_TOOLS_OPENAI_KEY") or load_env_key("OPENAI_API_KEY")


def run_google_api(*args):
    """Ejecuta google_api.py y devuelve el resultado."""
    r = subprocess.run(
        [VENV_PYTHON, API_SCRIPT] + list(args),
        capture_output=True, text=True, timeout=60,
        env={**os.environ, "PYTHONIOENCODING": "utf-8", "HERMES_HOME": HERMES_HOME}
    )
    if r.returncode != 0:
        return {"error": r.stderr[:500]}
    try:
        return {"ok": json.loads(r.stdout)}
    except json.JSONDecodeError:
        return {"ok": r.stdout.strip()}


def transcribe_audio(audio_wav: bytes) -> str:
    """STT con OpenAI Whisper."""
    if not OPENAI_KEY:
        return ""
    boundary = "----WhisperBoundary"
    body = (
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-1\r\n"
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"language\"\r\n\r\nes\r\n"
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n"
        f"Content-Type: audio/wav\r\n\r\n"
    ).encode() + audio_wav + f"\r\n--{boundary}--\r\n".encode()
    req = Request("https://api.openai.com/v1/audio/transcriptions", data=body)
    req.add_header("Authorization", f"Bearer {OPENAI_KEY}")
    req.add_header("Content-Type", f"multipart/form-data; boundary={boundary}")
    try:
        with urlopen(req, timeout=30) as resp:
            return json.loads(resp.read()).get("text", "").strip()
    except: return ""


def chat_with_jarvis(text: str) -> str:
    """Habla con Jarvis via API server."""
    body = json.dumps({
        "model": "grok-4",
        "messages": [{"role": "user", "content": text}],
        "max_tokens": 300,
    }).encode()
    req = Request(API_URL, data=body, method="POST")
    req.add_header("Authorization", f"Bearer {API_KEY}")
    req.add_header("Content-Type", "application/json")
    try:
        with urlopen(req, timeout=60) as resp:
            data = json.loads(resp.read())
            return data["choices"][0]["message"]["content"].strip()
    except: return ""


def tts(text: str):
    """TTS con Windows SAPI."""
    try:
        safe = text.replace("'", "''")
        subprocess.run(
            ["powershell", "-Command",
             "Add-Type -AssemblyName System.Speech; "
             f"$s = New-Object System.Speech.Synthesis.SpeechSynthesizer; "
             f"$s.Speak('{safe}')"],
            capture_output=True, timeout=30)
    except: pass


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        try:
            payload = json.loads(body)
        except:
            self.send_error(400, "invalid json"); return

        action = payload.get("action", "")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()

        if action == "ping":
            self.wfile.write(json.dumps({"status": "ok"}).encode())
        elif action == "gmail_search":
            result = run_google_api("gmail", "search", payload.get("query", "is:unread"), "--max", str(payload.get("max", "5")))
            self.wfile.write(json.dumps(result, ensure_ascii=False).encode())
        elif action == "gmail_get":
            result = run_google_api("gmail", "get", payload["id"])
            self.wfile.write(json.dumps(result, ensure_ascii=False).encode())
        elif action == "calendar_list":
            result = run_google_api("calendar", "list")
            self.wfile.write(json.dumps(result, ensure_ascii=False).encode())
        elif action == "drive_search":
            result = run_google_api("drive", "search", payload.get("query", ""), "--max", str(payload.get("max", "5")))
            self.wfile.write(json.dumps(result, ensure_ascii=False).encode())
        elif action == "transcribe":
            audio_b64 = payload.get("audio", "")
            import base64
            wav_bytes = base64.b64decode(audio_b64)
            text = transcribe_audio(wav_bytes)
            self.wfile.write(json.dumps({"text": text}, ensure_ascii=False).encode())
        elif action == "chat":
            text = payload.get("message", "")
            reply = chat_with_jarvis(text)
            self.wfile.write(json.dumps({"reply": reply}, ensure_ascii=False).encode())
        elif action == "tts":
            tts(payload.get("text", ""))
            self.wfile.write(json.dumps({"status": "ok"}).encode())
        else:
            self.wfile.write(json.dumps({"error": "unknown action"}).encode())

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def log_message(self, format, *args):
        if "200" in format: return
        print(f"[tools] {args[0]}", flush=True)


if __name__ == "__main__":
    port = int(os.environ.get("TOOLS_PORT", "8646"))
    server = HTTPServer(("0.0.0.0", port), Handler)
    print(f"Jarvis Tools en http://0.0.0.0:{port}/ (Gmail, Calendar, Drive, STT, TTS)")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nTools detenido.")
        server.server_close()
