"""
jarvis_wake.py — Wake word "Jarvis" con Porcupine.

Escucha continuamente. Al detectar "Jarvis":
  1. Graba audio hasta silencio
  2. Transcribe con OpenAI Whisper
  3. Envia texto a Hermes (misma sesion)
  4. Responde con TTS (Edge gratuito o OpenAI)

Ejecutar: python scripts/jarvis_wake.py
"""

import os, sys, json, time, queue, tempfile, threading, subprocess

import numpy as np
import sounddevice as sd
import pvporcupine

from urllib.request import Request, urlopen
from urllib.error import HTTPError

# === CONFIG ===
HERMES_HOME = os.environ.get("HERMES_HOME", os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
HERMES_BIN = os.path.join(
    os.environ.get("LOCALAPPDATA", os.path.expanduser("~")),
    "hermes", "hermes-agent", "venv", "Scripts", "hermes.exe"
)

OPENAI_KEY = None
def _load_keys():
    global OPENAI_KEY, PICOVOICE_KEY
    env_file = os.path.join(HERMES_HOME, ".env")
    try:
        with open(env_file) as f:
            for line in f:
                line = line.strip()
                if line.startswith("VOICE_TOOLS_OPENAI_KEY="):
                    OPENAI_KEY = line.split("=", 1)[1].strip().strip("\"'")
                elif line.startswith("OPENAI_API_KEY=") and not OPENAI_KEY:
                    OPENAI_KEY = line.split("=", 1)[1].strip().strip("\"'")
                elif line.startswith("PICOVOICE_ACCESS_KEY="):
                    PICOVOICE_KEY = line.split("=", 1)[1].strip().strip("\"'")
    except FileNotFoundError:
        pass
    OPENAI_KEY = OPENAI_KEY or os.environ.get("VOICE_TOOLS_OPENAI_KEY") or os.environ.get("OPENAI_API_KEY") or ""
    PICOVOICE_KEY = PICOVOICE_KEY or os.environ.get("PICOVOICE_ACCESS_KEY") or ""

PICOVOICE_KEY = ""

SAMPLE_RATE = 16000
SILENCE_THRESHOLD = 0.02
SILENCE_DURATION = 1.5
MAX_RECORD_SECONDS = 10

porcupine = None
audio_queue = queue.Queue()
is_recording = False
recording_frames = []


def transcribe(audio_data: bytes) -> str:
    """Envia audio a OpenAI Whisper y devuelve texto."""
    if not OPENAI_KEY:
        return "ERROR: no API key"

    boundary = "----WhisperBoundary"
    body = (
        f"--{boundary}\r\n"
        'Content-Disposition: form-data; name="model"\r\n\r\nwhisper-1\r\n'
        f"--{boundary}\r\n"
        'Content-Disposition: form-data; name="language"\r\n\r\nes\r\n'
        f"--{boundary}\r\n"
        'Content-Disposition: form-data; name="file"; filename="audio.wav"\r\n'
        'Content-Type: audio/wav\r\n\r\n'
    ).encode() + audio_data + f"\r\n--{boundary}--\r\n".encode()

    req = Request("https://api.openai.com/v1/audio/transcriptions", data=body)
    req.add_header("Authorization", f"Bearer {OPENAI_KEY}")
    req.add_header("Content-Type", f"multipart/form-data; boundary={boundary}")

    try:
        with urlopen(req, timeout=30) as resp:
            result = json.loads(resp.read())
            return result.get("text", "").strip()
    except Exception as e:
        return f"ERROR: {e}"


def speak(text: str):
    """TTS via Edge (gratuito, usa el sistema)."""
    try:
        import subprocess
        # Guardar texto en temp y usar edge-tts o powershell
        cmd = (
            'Add-Type -AssemblyName System.Speech; '
            f'$s = New-Object System.Speech.Synthesis.SpeechSynthesizer; '
            f'$s.Speak(\'{text.replace(chr(39), chr(39)+chr(39))}\')'
        )
        subprocess.run(["powershell", "-Command", cmd],
                       capture_output=True, timeout=30)
    except Exception:
        pass


def query_hermes(text: str) -> str:
    """Envia texto a Hermes y devuelve respuesta."""
    try:
        result = subprocess.run(
            [HERMES_BIN, "chat", "-q", text, "--max-turns", "5", "--continue", "jarvis-voice"],
            capture_output=True, text=True, timeout=120,
            env={**os.environ, "HERMES_HOME": HERMES_HOME,
                 "PYTHONIOENCODING": "utf-8"},
            cwd=HERMES_HOME,
        )
        # Extraer solo la respuesta del output
        output = result.stdout
        # Buscar contenido entre las lineas del banner
        lines = output.split('\n')
        response_lines = []
        in_response = False
        for line in lines:
            # Skip ANSI and metadata
            clean = line.strip()
            if not clean or clean.startswith('\x1b') or '─' in clean:
                continue
            if clean.startswith('Resume this session') or 'Session:' in clean:
                break
            response_lines.append(clean)
        return ' '.join(response_lines).strip() or "(sin respuesta)"
    except subprocess.TimeoutExpired:
        return "(timeout)"
    except Exception as e:
        return f"(error: {e})"


def audio_callback(indata, frames, time_info, status):
    """Callback de sounddevice: recibe audio del microfono."""
    audio_queue.put(indata.copy())


def process_audio():
    """Thread: procesa audio en busca de wake word y graba."""
    global is_recording, recording_frames

    while True:
        frame = audio_queue.get()
        audio_16k = (frame[:, 0] * 32767).astype(np.int16)

        if is_recording:
            recording_frames.extend(audio_16k.tolist())
            continue

        pcm = audio_16k.tolist()
        keyword_index = porcupine.process(pcm)
        if keyword_index == 0:  # jarvis
            print("\n🎙️  ¡Jarvis activado! Habla...", flush=True)
            is_recording = True
            recording_frames = []

            # Grabar hasta silencio o maximo
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
                    elif now - silence_start > SILENCE_DURATION:
                        break
                else:
                    silence_start = None

                if len(recording_frames) / SAMPLE_RATE > MAX_RECORD_SECONDS:
                    break

            is_recording = False
            print("   Procesando...", flush=True)

            # Convertir a WAV
            audio_np = np.array(recording_frames, dtype=np.int16)
            import io, struct, wave
            wav_buf = io.BytesIO()
            with wave.open(wav_buf, 'wb') as wf:
                wf.setnchannels(1)
                wf.setsampwidth(2)
                wf.setframerate(SAMPLE_RATE)
                wf.writeframes(audio_np.tobytes())
            wav_bytes = wav_buf.getvalue()

            # STT
            text = transcribe(wav_bytes)
            print(f"   Tú: {text}", flush=True)

            if text and not text.startswith("ERROR"):
                # Hermes
                print("   Jarvis pensando...", flush=True)
                response = query_hermes(text)
                print(f"   Jarvis: {response}", flush=True)

                # TTS
                if response and response != "(sin respuesta)":
                    threading.Thread(target=speak, args=(response,), daemon=True).start()

            print("   Escuchando...", flush=True)


def main():
    global porcupine
    _load_keys()

    if not PICOVOICE_KEY:
        print("ERROR: PICOVOICE_ACCESS_KEY no configurado en .env")
        print("Obten uno gratis en https://console.picovoice.ai/")
        sys.exit(1)

    porcupine = pvporcupine.create(
        access_key=PICOVOICE_KEY,
        keywords=["jarvis"],
    )

    print("=" * 50)
    print("  Jarvis Wake — di 'Jarvis' para activar")
    print("  Ctrl+C para salir")
    print("=" * 50)

    # Verificar microfono
    devices = sd.query_devices()
    input_devices = [d for d in devices if d['max_input_channels'] > 0]
    if not input_devices:
        print("ERROR: No se encontro microfono")
        sys.exit(1)
    print(f"  Microfono: {input_devices[0]['name']}")
    print("  Escuchando...")

    # Iniciar thread de procesamiento
    processor = threading.Thread(target=process_audio, daemon=True)
    processor.start()

    # Stream de audio
    with sd.InputStream(
        samplerate=SAMPLE_RATE,
        channels=1,
        callback=audio_callback,
        blocksize=porcupine.frame_length,
    ):
        try:
            while True:
                time.sleep(0.1)
        except KeyboardInterrupt:
            print("\nJarvis Wake detenido.")

    porcupine.delete()


if __name__ == "__main__":
    main()
