"""
jarvis_wake.py — Wake word "Hey Jarvis" con OpenWakeWord.

Optimizado para baja latencia:
  - STT local: faster-whisper (sin red)
  - TTS local: pyttsx3 (sin subprocess)
  - Hermes: HTTP POST a API server :8642 (sin spawn)

Ejecutar: python scripts/jarvis_wake.py
"""

import os, sys, json, time, io, queue, wave, threading

import numpy as np
import sounddevice as sd
import requests
from openwakeword.model import Model

# === CONFIG ===
HERMES_HOME = os.environ.get(
    "HERMES_HOME",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."),
)
HERMES_API = os.environ.get("HERMES_API_URL", "http://127.0.0.1:8642/v1/chat/completions")
API_KEY = os.environ.get("API_SERVER_KEY", "jarvis-api-key-secreto")
MODEL_NAME = os.environ.get("LLM_MODEL", "grok-4")

SAMPLE_RATE = 16000
CHUNK_SIZE = 1280
SILENCE_THRESHOLD = 0.02
SILENCE_SECONDS = 0.8
MAX_RECORD_SECS = 10
WAKE_THRESHOLD = 0.25

# === MOTORES (inicializados en main) ===
whisper_model = None
model = None
audio_queue = queue.Queue()
is_recording = False
recording_frames = []


def transcribe(audio_wav: bytes) -> str:
    """STT local con faster-whisper (base model, CPU int8)."""
    global whisper_model
    import tempfile
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
        f.write(audio_wav)
        tmp = f.name
    try:
        segments, _ = whisper_model.transcribe(tmp, language="es", beam_size=5)
        text = " ".join(s.text for s in segments).strip()
    except Exception as e:
        text = f"ERROR: {e}"
    os.unlink(tmp)
    return text


def speak(text: str):
    """TTS local con pyttsx3 en hilo separado (evita bloqueos)."""
    def _speak():
        try:
            import pyttsx3
            engine = pyttsx3.init()
            engine.setProperty("rate", 180)
            engine.say(text)
            engine.runAndWait()
        except Exception:
            pass
    t = threading.Thread(target=_speak, daemon=True)
    t.start()
    t.join(timeout=15)  # no bloquear mas de 15s


def query_hermes(text: str) -> str:
    """HTTP POST al API server de Hermes (:8642)."""
    try:
        r = requests.post(
            HERMES_API,
            json={
                "model": MODEL_NAME,
                "messages": [{"role": "user", "content": text}],
                "max_tokens": 300,
            },
            headers={
                "Authorization": f"Bearer {API_KEY}",
                "Content-Type": "application/json",
            },
            timeout=60,
        )
        if r.status_code == 200:
            data = r.json()
            return data["choices"][0]["message"]["content"].strip()
        return f"(HTTP {r.status_code})"
    except requests.Timeout:
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

        prediction = model.predict(audio_16k)
        score = prediction.get("hey_jarvis", 0)

        if score >= WAKE_THRESHOLD:
            print(f"\n   Activado (score: {score:.2f})", flush=True)
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

            # WAV
            audio_np = np.array(recording_frames, dtype=np.int16)
            wav_buf = io.BytesIO()
            with wave.open(wav_buf, "wb") as wf:
                wf.setnchannels(1)
                wf.setsampwidth(2)
                wf.setframerate(SAMPLE_RATE)
                wf.writeframes(audio_np.tobytes())

            start_stt = time.time()
            text = transcribe(wav_buf.getvalue())
            print(f"   STT ({time.time()-start_stt:.1f}s): {text}", flush=True)

            if text and not text.startswith("ERROR"):
                start_llm = time.time()
                response = query_hermes(text)
                print(f"   Jarvis ({time.time()-start_llm:.1f}s): {response}", flush=True)

                if response and not response.startswith("("):
                    speak(response)

                # Drenar audio residual
                drain = time.time()
                while time.time() - drain < 0.5:
                    try:
                        audio_queue.get(timeout=0.1)
                    except queue.Empty:
                        break

            print("   Escuchando...", flush=True)


def main():
    global model, whisper_model

    import openwakeword
    openwakeword.utils.download_models()

    # === INICIALIZACIONES PESADAS (solo una vez) ===
    print("Cargando motores...", flush=True)

    t_start = time.time()
    model = Model(wakeword_models=["hey_jarvis"])
    print(f"  OpenWakeWord: {time.time()-t_start:.1f}s", flush=True)

    t_start = time.time()
    from faster_whisper import WhisperModel
    whisper_model = WhisperModel("base", device="cpu", compute_type="int8")
    print(f"  faster-whisper: {time.time()-t_start:.1f}s", flush=True)

    print("  faster-whisper loaded", flush=True)

    print("  pyttsx3: se inicializa en cada llamada", flush=True)

    # === ARRANQUE ===
    print("=" * 50)
    print("  Jarvis Wake — 'Hey Jarvis'")
    print("  STT: faster-whisper | TTS: pyttsx3 | LLM: API :8642")
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
