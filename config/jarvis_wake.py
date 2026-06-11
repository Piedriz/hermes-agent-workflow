"""
jarvis_wake.py — Wake word "Hey Jarvis" con OpenWakeWord (GRATIS).

Escucha continuamente. Al detectar "Hey Jarvis":
  1. Graba audio hasta silencio
  2. Transcribe con OpenAI Whisper
  3. Envia texto a Hermes (sesion persistente)
  4. Responde con TTS (Edge gratuito)

Ejecutar: python scripts/jarvis_wake.py
"""

import os, sys, json, time, io, queue, wave, struct, threading, subprocess

import numpy as np
import sounddevice as sd
from openwakeword.model import Model

# === CONFIG ===
HERMES_HOME = os.environ.get(
    "HERMES_HOME",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."),
)
HERMES_BIN = os.path.join(
    os.environ.get("LOCALAPPDATA", os.path.expanduser("~")),
    "hermes", "hermes-agent", "venv", "Scripts", "hermes.exe",
)

OPENAI_KEY = ""

def _load_keys():
    global OPENAI_KEY
    env_file = os.path.join(HERMES_HOME, ".env")
    try:
        with open(env_file) as f:
            for line in f:
                line = line.strip()
                if line.startswith("VOICE_TOOLS_OPENAI_KEY="):
                    OPENAI_KEY = line.split("=", 1)[1].strip().strip("\"'")
                elif line.startswith("OPENAI_API_KEY=") and not OPENAI_KEY:
                    OPENAI_KEY = line.split("=", 1)[1].strip().strip("\"'")
    except FileNotFoundError:
        pass
    OPENAI_KEY = (
        OPENAI_KEY
        or os.environ.get("VOICE_TOOLS_OPENAI_KEY")
        or os.environ.get("OPENAI_API_KEY")
        or ""
    )

SAMPLE_RATE = 16000
CHUNK_SIZE = 1280  # 80ms at 16kHz
SILENCE_THRESHOLD = 0.02
SILENCE_SECONDS = 1.5
MAX_RECORD_SECS = 10
WAKE_THRESHOLD = 0.15  # sin normalizacion, puntuaciones mas bajas

model = None
audio_queue = queue.Queue()
is_recording = False
recording_frames = []


def transcribe(audio_wav: bytes) -> str:
    if not OPENAI_KEY:
        return "ERROR: sin API key"
    boundary = "----WhisperBoundary"
    body = (
        f"--{boundary}\r\n"
        'Content-Disposition: form-data; name="model"\r\n\r\nwhisper-1\r\n'
        f"--{boundary}\r\n"
        'Content-Disposition: form-data; name="language"\r\n\r\nes\r\n'
        f"--{boundary}\r\n"
        'Content-Disposition: form-data; name="file"; filename="audio.wav"\r\n'
        "Content-Type: audio/wav\r\n\r\n"
    ).encode() + audio_wav + f"\r\n--{boundary}--\r\n".encode()

    from urllib.request import Request, urlopen
    req = Request("https://api.openai.com/v1/audio/transcriptions", data=body)
    req.add_header("Authorization", f"Bearer {OPENAI_KEY}")
    req.add_header("Content-Type", f"multipart/form-data; boundary={boundary}")
    try:
        with urlopen(req, timeout=30) as resp:
            return json.loads(resp.read()).get("text", "").strip()
    except Exception as e:
        return f"ERROR: {e}"


def speak(text: str):
    """TTS via Windows SAPI (gratuito, offline, sincrono)."""
    try:
        safe = text.replace("'", "''")
        subprocess.run(
            [
                "powershell", "-Command",
                "Add-Type -AssemblyName System.Speech; "
                f"$s = New-Object System.Speech.Synthesis.SpeechSynthesizer; "
                f"$s.Speak('{safe}')",
            ],
            capture_output=True, timeout=60,
        )
    except Exception:
        pass


def query_hermes(text: str) -> str:
    try:
        r = subprocess.run(
            [HERMES_BIN, "chat", "-q", text, "--max-turns", "5"],
            capture_output=True, text=True, timeout=120,
            env={**os.environ, "HERMES_HOME": HERMES_HOME, "PYTHONIOENCODING": "utf-8"},
            cwd=HERMES_HOME,
            encoding="utf-8",
        )
        output = r.stdout
        # Extraer solo el texto de respuesta (despues del banner de Hermes)
        in_box = False
        lines = []
        for line in output.split('\n'):
            if '╭─' in line or '┌─' in line:
                in_box = True
                continue
            if '╰─' in line or '└─' in line:
                in_box = False
                continue
            if not in_box:
                continue
            # Limpiar bordes y ANSI
            clean = line.strip()
            # Eliminar caracteres de borde
            clean = clean.lstrip('│╭╰┌└╮╯ ')
            clean = clean.strip()
            # Eliminar secuencias ANSI
            import re
            clean = re.sub(r'\x1b\[[0-9;]*m', '', clean)
            if clean and not clean.startswith('Query:') and not clean.startswith('Session:'):
                lines.append(clean)
        result = ' '.join(lines).strip()
        return result if result else "(sin respuesta)"
    except subprocess.TimeoutExpired:
        return "(timeout)"
    except Exception as e:
        return f"(error: {e})"


def audio_callback(indata, frames, time_info, status):
    audio_queue.put(indata.copy())


def process_audio():
    global is_recording, recording_frames

    while True:
        frame = audio_queue.get()
        audio_16k = (frame[:, 0] * 32767).astype(np.int16)

        if is_recording:
            recording_frames.extend(audio_16k.tolist())
            continue

        # Wake word detection (sin normalizar, el modelo espera audio crudo)
        prediction = model.predict(audio_16k)
        score = prediction.get("hey_jarvis", 0)

        if score >= WAKE_THRESHOLD:
            print(f"\n   Jarvis activado! (score: {score:.2f})", flush=True)
            is_recording = True
            recording_frames = list(audio_16k.tolist())

            silence_start = None
            while True:
                frame = audio_queue.get()
                samples = (frame[:, 0] * 32767).astype(np.int16)
                recording_frames.extend(samples.tolist())
                volume = np.abs(frame).mean()
                now = time.time()

                if volume < SILENCE_THRESHOLD:
                    if silence_start is None:
                        silence_start = now
                    elif now - silence_start > SILENCE_SECONDS:
                        break
                else:
                    silence_start = None

                if len(recording_frames) / SAMPLE_RATE > MAX_RECORD_SECS:
                    break

            is_recording = False

            # WAV (normalizar volumen bajo)
            audio_np = np.array(recording_frames, dtype=np.int16).astype(np.float32)
            peak = np.max(np.abs(audio_np))
            if peak > 1:
                audio_np = (audio_np / peak * 32767).astype(np.int16)
            else:
                audio_np = audio_np.astype(np.int16)
            wav_buf = io.BytesIO()
            with wave.open(wav_buf, "wb") as wf:
                wf.setnchannels(1)
                wf.setsampwidth(2)
                wf.setframerate(SAMPLE_RATE)
                wf.writeframes(audio_np.tobytes())

            text = transcribe(wav_buf.getvalue())
            print(f"   Tu: {text}", flush=True)

            if text and not text.startswith("ERROR"):
                print("   Jarvis pensando...", flush=True)
                response = query_hermes(text)
                print(f"   Jarvis: {response}", flush=True)
                if response and response != "(sin respuesta)":
                    speak(response)  # sincrono: espera a que termine de hablar

                # Descartar audio residual del parlante (evita feedback loop)
                drain_start = time.time()
                while time.time() - drain_start < 1.0:
                    try:
                        audio_queue.get(timeout=0.1)
                    except queue.Empty:
                        break
                print("   Escuchando...", flush=True)


def main():
    global model
    _load_keys()

    import openwakeword
    openwakeword.utils.download_models()

    model = Model(wakeword_models=["hey_jarvis"], vad_threshold=0)

    print("=" * 50)
    print("  Jarvis Wake — di 'Hey Jarvis' para activar")
    print("  OpenWakeWord (gratis, sin API key)")
    print("  Ctrl+C para salir")
    print("=" * 50)

    devices = sd.query_devices()
    inputs = [d for d in devices if d["max_input_channels"] > 0]
    if not inputs:
        print("ERROR: No hay microfono")
        sys.exit(1)
    print(f"  Micro: {inputs[0]['name']}")
    print("  Escuchando...")

    processor = threading.Thread(target=process_audio, daemon=True)
    processor.start()

    with sd.InputStream(samplerate=SAMPLE_RATE, channels=1, callback=audio_callback, blocksize=CHUNK_SIZE):
        try:
            while True:
                time.sleep(0.1)
        except KeyboardInterrupt:
            print("\nJarvis Wake detenido.")


if __name__ == "__main__":
    main()
