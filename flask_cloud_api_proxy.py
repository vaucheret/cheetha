# flask_whatsapp_proxy.py
from flask import Flask, request, jsonify
import os
import requests
import json
import openai

app = Flask(__name__)

# === Config ===
PROLOG_URL = 'http://localhost:8000/chat'   # backend Prolog
VERIFY_TOKEN = os.getenv("META_VERIFY_TOKEN", "mitokendeverificacion1739")
ACCESS_TOKEN = os.getenv("META_ACCESS_TOKEN", "EAAUOKrSkM2QBPJp5Mw0YyhNi8CdZCrUjhmQAjbWVDJaBbGm3bBRMbAs4BjHsnycDRWSmmFLc9AQMqNsXR8CPanwbEYjyZC45wX3ZCKIHjcTCxB2He4k8zzlFYZCwYMnu3zi3yormDU1YtNorOCZBS1XvRl02wIM0JNSAnbwqKO1D9Od0y1PT3KxCTpuRRWnyQrXUCmZCLA53NDUj7HyuDMZA6C9qu4J4f8Q0ZCQGkIPFLoMk7DugdGMe3SO6TS53d8sZD")
PHONE_NUMBER_ID = os.getenv("META_PHONE_NUMBER_ID", "703793806159035")
OPENAI_API_KEY = os.getenv("OPENAI_API_KEY")

openai.api_key = OPENAI_API_KEY

GRAPH_URL = f"https://graph.facebook.com/v20.0/{PHONE_NUMBER_ID}/messages"
HEADERS = {
    "Authorization": f"Bearer {ACCESS_TOKEN}",
    "Content-Type": "application/json"
}

# --- Normalización de número para Argentina y otros ---
def normalize_whatsapp_number(to):
    to = str(to).replace("+", "").replace(" ", "").replace("-", "")

    if to.startswith("54"):  # Argentina
        if to[2] == "9":   # quitar el 9 extra
            to = to[:2] + to[3:]
        area = to[2:5]
        local = to[5:]
        # to = "54" + area + "15" + local
        to = "54" + area + local        
    else:
        if not to.startswith("+"):
            to = "+" + to
    return to

def send_whatsapp_text(to, body):
    to = normalize_whatsapp_number(to)
    payload = {
        "messaging_product": "whatsapp",
        "to": to,
        "text": {"body": body}
    }
    r = requests.post(GRAPH_URL, headers=HEADERS, json=payload, timeout=15)
    if r.status_code >= 300:
        print("❌ Error al enviar mensaje a WhatsApp:", r.status_code, r.text)
    return r.status_code < 300

# --- Funciones para audio ---
def get_media_url(media_id):
    url = f"https://graph.facebook.com/v20.0/{media_id}"
    headers = {"Authorization": f"Bearer {ACCESS_TOKEN}"}
    res = requests.get(url, headers=headers).json()
    return res.get("url")

def download_media(media_url):
    headers = {"Authorization": f"Bearer {ACCESS_TOKEN}"}
    res = requests.get(media_url, headers=headers)
    return res.content

def transcribe_audio(audio_bytes):
    with open("temp.ogg", "wb") as f:
        f.write(audio_bytes)
    with open("temp.ogg", "rb") as f:
        transcription = openai.audio.transcriptions.create(
            model="gpt-4o-mini-transcribe",  # o "whisper-1"
            file=f
        )
    return transcription.text

# --- Rutas ---
@app.route("/", methods=["GET"])
def index():
    return "✅ Flask WhatsApp Proxy activo."

@app.route("/webhook", methods=["GET"])
def verify():
    mode = request.args.get("hub.mode")
    token = request.args.get("hub.verify_token")
    challenge = request.args.get("hub.challenge")

    if mode == "subscribe" and token == VERIFY_TOKEN:
        print("✅ Webhook verificado")
        return challenge, 200
    else:
        print("❌ Verificación fallida")
        return "Forbidden", 403

@app.route("/webhook", methods=["POST"])
def webhook():
    data = request.get_json()
    print("📩 Evento recibido:", json.dumps(data, ensure_ascii=False, indent=2))

    try:
        entry = data.get("entry", [])[0]
        change = entry.get("changes", [])[0]
        value = change.get("value", {})
        messages = value.get("messages", [])
        if not messages:
            return jsonify({"status": "ignored"}), 200

        msg = messages[0]
        sender_wa = msg.get("from")
        msg_type = msg.get("type")
        text = None

        # --- Texto normal ---
        if msg_type == "text":
            text = msg["text"]["body"]

        # --- Botones/interactive ---
        elif msg_type == "button":
            text = msg["button"]["text"]
        elif msg_type == "interactive":
            inter = msg.get("interactive", {})
            if "button_reply" in inter:
                text = inter["button_reply"]["title"]
            elif "list_reply" in inter:
                text = inter["list_reply"]["title"]

        # --- Audio / Voice ---
        elif msg_type in ["audio", "voice"]:
            media_id = msg[msg_type]["id"]
            media_url = get_media_url(media_id)
            audio_bytes = download_media(media_url)
            text = transcribe_audio(audio_bytes)
            send_whatsapp_text(sender_wa, f"📝 Transcripción: {text}")

        # --- Si no se reconoció nada ---
        if not text:
            send_whatsapp_text(sender_wa, "Recibí tu mensaje 👍 (tipo no soportado).")
            return jsonify({"status": "ok"}), 200

        print(f"👤 {sender_wa}: {text}")

        # Enviar a Prolog
        prolog_payload = {"message": {"user_id": sender_wa, "text": text}}
        try:
            res = requests.post(PROLOG_URL, json=prolog_payload, timeout=20)
            prolog_reply = res.json().get("respuesta", "⚠️ No se pudo obtener respuesta de Prolog")
        except Exception as e:
            print("❌ Error Prolog:", e)
            prolog_reply = "⚠️ Error al conectar con el motor de diálogo."

        # Responder al usuario
        send_whatsapp_text(sender_wa, prolog_reply)
        print("✅ Respuesta enviada a WhatsApp")

        return jsonify({"status": "ok"}), 200

    except Exception as e:
        print("❌ Error parseando evento:", e)
        return jsonify({"status": "error"}), 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
