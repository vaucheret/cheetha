# flask_whatsapp_proxy.py
from flask import Flask, request, jsonify
import time
from dotenv import load_dotenv
import os
import requests
import json
import uuid
import re
from pathlib import Path
from openai import OpenAI

app = Flask(__name__, static_url_path="/static", static_folder="static")


load_dotenv()

# === Config ===
PROLOG_URL = 'http://localhost:8000/chat'
VERIFY_TOKEN = os.getenv("META_VERIFY_TOKEN")
ACCESS_TOKEN = os.getenv("META_ACCESS_TOKEN")
PHONE_NUMBER_ID = os.getenv("META_PHONE_NUMBER_ID")
OPENAI_API_KEY = os.getenv("OPENAI_API_KEY")

client = OpenAI(api_key=OPENAI_API_KEY)

GRAPH_URL = f"https://graph.facebook.com/v20.0/{PHONE_NUMBER_ID}/messages"
HEADERS = {
    "Authorization": f"Bearer {ACCESS_TOKEN}",
    "Content-Type": "application/json"
}


processed_messages = {}  # dict con id → timestamp

def is_duplicate(message_id, ttl=300):
    """Devuelve True si el mensaje ya fue procesado en los últimos `ttl` segundos"""
    now = time.time()
    if message_id in processed_messages:
        if now - processed_messages[message_id] < ttl:
            return True
    processed_messages[message_id] = now
    # limpieza de viejos
    for mid, ts in list(processed_messages.items()):
        if now - ts > ttl:
            processed_messages.pop(mid, None)
    return False

# --- Enviar documento (PDF) ---
def send_whatsapp_pdf(to, pdf_url, filename=None):
    try:

        to_normalized = normalize_whatsapp_number(to).replace("+", "")
        visible_filename = f"{to_normalized}.pdf"
        
        if not filename:
            filename = os.path.basename(pdf_url.split("?")[0]) or f"{uuid.uuid4().hex}.pdf"
        local_filename = f"{uuid.uuid4().hex}_{filename}"
        local_path = os.path.join("static", local_filename)

        # Descargar PDF
        r = requests.get(pdf_url, timeout=20)
        if r.status_code != 200:
            print("❌ Error al descargar PDF:", r.status_code, r.text)
            return False
        with open(local_path, "wb") as f:
            f.write(r.content)

        # URL pública
        pdf_public_url = f"{request.host_url}static/{local_filename}"

        payload = {
            "messaging_product": "whatsapp",
            "to": normalize_whatsapp_number(to),
            "type": "document",
            "document": {
                "link": pdf_public_url,
                "filename": visible_filename
            }
        }
        res = requests.post(GRAPH_URL, headers=HEADERS, json=payload, timeout=25)
        if res.status_code >= 300:
            print("❌ Error enviando PDF:", res.status_code, res.text)
            return False
        else:
            print(f"✅ PDF enviado: {pdf_public_url}")
            return True
    except Exception as e:
        print("❌ Error en send_whatsapp_pdf:", e)
        return False


def extraer_link_pdf(text):
    """Si hay un link a .pdf en el texto lo devuelve, si no None."""
    if not text:
        return None
    m = re.search(r'(https?://\S+\.pdf)', text, re.IGNORECASE)
    return m.group(1) if m else None


# --- Normalización de números ---
def normalize_whatsapp_number(to):
    to = str(to).replace("+", "").replace(" ", "").replace("-", "")
    if to.startswith("54"):
        if to[2] == "9":
            to = to[:2] + to[3:]
        area = to[2:5]
        local = to[5:]
        to = "54" + area + local
    else:
        if not to.startswith("+"):
            to = "+" + to
    return to


def contiene_link(text):
    """Detecta si el texto contiene un link http/https."""
    if not text:
        return False
    return bool(re.search(r'https?://\S+', text))


# --- Enviar texto ---
def send_whatsapp_text(to, body):
    to = normalize_whatsapp_number(to)
    payload = {
        "messaging_product": "whatsapp",
        "to": to,
        "text": {"body": body}
    }
    r = requests.post(GRAPH_URL, headers=HEADERS, json=payload, timeout=25)
    if r.status_code >= 300:
        print("❌ Error al enviar mensaje a WhatsApp:", r.status_code, r.text)
    return r.status_code < 300

# --- Enviar audio (TTS en MP3 con streaming) ---
def text_to_speech_and_send(to, text):
    try:
        filename = f"{uuid.uuid4().hex}.mp3"
        filepath = os.path.join("static", filename)

        with client.audio.speech.with_streaming_response.create(
            model="gpt-4o-mini-tts",
            voice="alloy",
            input=text,
            response_format="mp3"
        ) as response:
            response.stream_to_file(filepath)

        audio_url = f"{request.host_url}static/{filename}"

        payload = {
            "messaging_product": "whatsapp",
            "to": normalize_whatsapp_number(to),
            "type": "audio",
            "audio": {"link": audio_url}
        }
        r = requests.post(GRAPH_URL, headers=HEADERS, json=payload, timeout=25)
        if r.status_code >= 300:
            print("❌ Error enviando audio:", r.status_code, r.text)
        else:
            print("✅ Audio enviado:", audio_url)
    except Exception as e:
        print("❌ Error en TTS:", e)

# --- Audio entrante ---
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
    """Guarda cada audio entrante con un nombre único y lo borra tras transcripción."""
    temp_filename = f"{uuid.uuid4().hex}.ogg"
    temp_path = os.path.join("static", temp_filename)
    try:
        with open(temp_path, "wb") as f:
            f.write(audio_bytes)

        with open(temp_path, "rb") as f:
            transcription = client.audio.transcriptions.create(
                model="gpt-4o-mini-transcribe",
                file=f
            )
        return transcription.text
    finally:
        try:
            os.remove(temp_path)
        except FileNotFoundError:
            pass

# --- Webhook ---

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
        msg_id = msg.get("id")

        if is_duplicate(msg_id):
            print(f"⚠️ Ignorado duplicado {msg_id}")
            return jsonify(success=True), 200
        
        sender_wa = msg.get("from")
        msg_type = msg.get("type")
        text = None
        reply_mode = "text"

        if msg_type == "text":
            text = msg["text"]["body"]
            reply_mode = "text"
        elif msg_type == "button":
            text = msg["button"]["text"]
            reply_mode = "text"
        elif msg_type == "interactive":
            inter = msg.get("interactive", {})
            if "button_reply" in inter:
                text = inter["button_reply"]["title"]
            elif "list_reply" in inter:
                text = inter["list_reply"]["title"]
            reply_mode = "text"
        elif msg_type in ["audio", "voice"]:
            media_id = msg[msg_type]["id"]
            media_url = get_media_url(media_id)
            audio_bytes = download_media(media_url)
            text = transcribe_audio(audio_bytes)
            print(f"📝 Transcripción: {text}")
            # send_whatsapp_text(sender_wa, f"📝 Transcripción: {text}")
            reply_mode = "audio"

        if not text:
            send_whatsapp_text(sender_wa, "Recibí tu mensaje 👍 (tipo no soportado).")
            return jsonify({"status": "ok"}), 200

        print(f"👤 {sender_wa}: {text}")

        # --- Pasar a Prolog ---
        prolog_payload = {"message": {"user_id": sender_wa, "text": text}}
        try:
            res = requests.post(PROLOG_URL, json=prolog_payload, timeout=65)
            prolog_reply = res.json().get("respuesta", "⚠️ No se pudo obtener respuesta de Prolog")
        except Exception as e:
            print("❌ Error Prolog:", e)
            prolog_reply = "⚠️ Error al conectar con el motor de diálogo."

        # --- Responder ---
        pdf_link = extraer_link_pdf(prolog_reply)

        if pdf_link:
            # Mandar el PDF como documento y además el texto como apoyo
            send_whatsapp_pdf(sender_wa, pdf_link)
            time.sleep(2)
            send_whatsapp_text(sender_wa, f"📄 Te envié el documento:\n{prolog_reply}")
        elif contiene_link(prolog_reply):
            send_whatsapp_text(sender_wa, prolog_reply)
        elif reply_mode == "text":
            send_whatsapp_text(sender_wa, prolog_reply)
        else:  # reply_mode == "audio"
          #  send_whatsapp_text(sender_wa, f"📖 Respuesta: {prolog_reply}")
            text_to_speech_and_send(sender_wa, prolog_reply)

        return jsonify({"status": "ok"}), 200

    except Exception as e:
        print("❌ Error parseando evento:", e)
        return jsonify({"status": "error"}), 200

if __name__ == "__main__":
    os.makedirs("static", exist_ok=True)
    app.run(host="0.0.0.0", port=8080)
