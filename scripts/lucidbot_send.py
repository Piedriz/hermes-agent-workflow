"""
lucidbot_send.py — Envia mensajes via Lucidbot API a WhatsApp.

Uso:
  python scripts/lucidbot_send.py \
    --phone "+573001234567" \
    --name "Juan" \
    --message "Hola, soy Jarvis. Tu reunión es mañana a las 3pm."

Requiere:
  LUCIDBOT_ACCESS_TOKEN en ~/.hermes/.env
  LUCIDBOT_FLOW_ID en ~/.hermes/.env (opcional, default en config)
"""

import argparse, json, os, sys, urllib.request, urllib.error

def get_env(key, default=None):
    val = os.environ.get(key, "").strip()
    if val:
        return val
    # Try reading from .env file
    env_file = os.path.join(os.environ.get("HERMES_HOME", os.path.expanduser("~/.hermes")), ".env")
    try:
        with open(env_file) as f:
            for line in f:
                line = line.strip()
                if line.startswith(f"{key}="):
                    return line.split("=", 1)[1].strip().strip("\"'")
    except FileNotFoundError:
        pass
    return default

def main():
    parser = argparse.ArgumentParser(description="Enviar mensaje via Lucidbot a WhatsApp")
    parser.add_argument("--phone", required=True, help="Numero de telefono con codigo pais (+57300...)")
    parser.add_argument("--name", default="", help="Nombre del contacto")
    parser.add_argument("--message", required=True, help="Contenido del mensaje")
    parser.add_argument("--priority", default="normal", choices=["urgent", "high", "normal", "low"])
    args = parser.parse_args()

    token = get_env("LUCIDBOT_ACCESS_TOKEN")
    if not token:
        print("ERROR: LUCIDBOT_ACCESS_TOKEN no configurado en .env", file=sys.stderr)
        sys.exit(1)

    flow_id = get_env("LUCIDBOT_FLOW_ID", "1779398376201")

    first, _, last = (args.name or "Usuario").partition(" ")
    payload = {
        "phone": args.phone,
        "first_name": first or "Usuario",
        "last_name": last or "",
        "gender": "male",
        "actions": [
            {"action": "set_field_value", "field_name": "original_user_quote", "value": args.message},
            {"action": "set_field_value", "field_name": "message_priority", "value": args.priority},
            {"action": "send_flow", "flow_id": int(flow_id)},
        ],
    }

    url = "https://panel.lucidbot.co/api/contacts"
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, method="POST")
    req.add_header("X-ACCESS-TOKEN", token)
    req.add_header("Content-Type", "application/json")

    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            body = resp.read().decode()
            print(f"OK {resp.status}: {body[:200]}")
    except urllib.error.HTTPError as e:
        body = e.read().decode() if e.fp else ""
        print(f"ERROR HTTP {e.code}: {body[:300]}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
