# flask_cloud_api_proxy_a2a.py
#
# Proxy de WhatsApp Cloud API que actúa como CLIENTE A2A del bridge
# (chita_a2a_server.py, puerto 8001), igual que cualquier agente externo
# que use a Chita como subagente. Alternativa a flask_cloud_api_proxy.py,
# que habla directo con Prolog /chat.
#
# Flujo:
#   WhatsApp → /webhook → message/send (JSON-RPC 2.0) al bridge → Prolog /chat_a2a
#     respuesta síncrona (Task.status.message) → WhatsApp
#   Resultados asíncronos (Kafka / callback DIDComm):
#     Prolog → bridge /internal/update_task → push HTTP a /a2a/push → WhatsApp
#     (el callback se registra en cada message/send vía pushNotificationConfig)
#
# La identificación DIDComm sigue pasando por acá: Sovra registra
# FLASKURL/identificacion_usuario, así que este proxy la reenvía a Prolog
# igual que el proxy directo. El resultado de la verificación vuelve por el
# canal A2A (push). /enviar_mensaje NO existe acá: con canal a2a el Prolog
# no lo usa.
from flask import Flask, request, jsonify
import time
import io
import threading
from urllib.parse import quote
from dotenv import load_dotenv
import qrcode
from qrcode.image.svg import SvgPathImage
import os
import requests
import json
import uuid
import re
import subprocess
from openai import OpenAI

app = Flask(__name__, static_url_path="/static", static_folder="static")


load_dotenv()

# === Config ===
A2A_FLASK_PORT = int(os.getenv("A2A_FLASK_PORT", "8071"))
A2A_BRIDGE_URL = os.getenv("A2A_BRIDGE_URL", "http://localhost:8001").rstrip("/")
A2A_PUSH_CALLBACK_URL = os.getenv(
    "A2A_PUSH_CALLBACK_URL", f"http://localhost:{A2A_FLASK_PORT}/a2a/push"
)
PROLOG_BASE_URL = os.getenv("PROLOG_BASE_URL")
IDENT_PROLOG_URL = f"{PROLOG_BASE_URL}/identificacion_usuario"
VERIFY_TOKEN = os.getenv("META_VERIFY_TOKEN")
ACCESS_TOKEN = os.getenv("META_ACCESS_TOKEN")
PHONE_NUMBER_ID = os.getenv("META_PHONE_NUMBER_ID")
OPENAI_API_KEY = os.getenv("OPENAI_API_KEY")

client = OpenAI(api_key=OPENAI_API_KEY)

GRAPH_URL = f"https://graph.facebook.com/v20.0/{PHONE_NUMBER_ID}/messages"
# Los adjuntos se suben con la Media Upload API y se mandan por media_id.
# Así no hace falta exponer una URL pública: el push del bridge llega por
# localhost y un link local no lo puede descargar Meta.
GRAPH_MEDIA_URL = f"https://graph.facebook.com/v20.0/{PHONE_NUMBER_ID}/media"
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


# ──────────────────────────────────────────────────────────────────────────────
# Sesión WhatsApp ↔ A2A (en memoria)
#
# RIESGO CONOCIDO (revisar más adelante): el mapeo vive sólo en este proceso.
# Si el proxy reinicia, se pierde el context_id/task_id y el próximo mensaje
# del usuario arranca una sesión A2A nueva (el trámite en curso en Prolog/bridge
# queda huérfano). Considerar persistencia (SQLite) si se pasa a producción.
# ──────────────────────────────────────────────────────────────────────────────

_sessions = {}           # sender_wa → {context_id, task_id, delivered_hist}
_task_to_sender = {}     # task_id → sender_wa
_sessions_lock = threading.Lock()


def _session_get(sender_wa):
    with _sessions_lock:
        sess = _sessions.get(sender_wa)
        return dict(sess) if sess else None


def _session_register(sender_wa, task):
    """Guarda/actualiza la sesión a partir de un Task devuelto por message/send.
    delivered_hist marca cuántos mensajes del history ya se entregaron a
    WhatsApp (la respuesta síncrona se entrega por fuera del push).
    delivered_arts hace lo propio con los artifacts (adjuntos), que el bridge
    va acumulando en el mismo task."""
    with _sessions_lock:
        previo = _sessions.get(sender_wa) or {}
        mismo_task = previo.get("task_id") == task.get("id")
        _sessions[sender_wa] = {
            "context_id": task.get("contextId"),
            "task_id": task.get("id"),
            "delivered_hist": len(task.get("history") or []),
            "delivered_arts": previo.get("delivered_arts", 0) if mismo_task else 0,
        }
        _task_to_sender[task.get("id")] = sender_wa


def _session_advance(sender_wa, total):
    with _sessions_lock:
        sess = _sessions.get(sender_wa)
        if sess:
            sess["delivered_hist"] = total


def _sender_for_task(task_id):
    with _sessions_lock:
        return _task_to_sender.get(task_id)


# ──────────────────────────────────────────────────────────────────────────────
# Cliente A2A
# ──────────────────────────────────────────────────────────────────────────────

def _text_from_parts(parts):
    """Concatena el texto de los TextParts de un Message A2A."""
    texts = []
    for p in parts or []:
        if isinstance(p, dict) and (p.get("kind") == "text" or "text" in p):
            texts.append(p.get("text", ""))
    return "\n".join(texts) if texts else ""


def a2a_send_message(sender_wa, text):
    """message/send al bridge A2A. Devuelve el Task actualizado.
    Registra A2A_PUSH_CALLBACK_URL como pushNotificationConfig para que los
    resultados asíncronos (Kafka/DIDComm) lleguen a /a2a/push."""
    sess = _session_get(sender_wa)
    msg = {
        "role": "user",
        "parts": [{"kind": "text", "text": text}],
        "messageId": str(uuid.uuid4()),
    }
    if sess:
        if sess.get("context_id"):
            msg["contextId"] = sess["context_id"]
        if sess.get("task_id"):
            msg["taskId"] = sess["task_id"]

    payload = {
        "jsonrpc": "2.0",
        "id": str(uuid.uuid4()),
        "method": "message/send",
        "params": {
            "message": msg,
            "pushNotificationConfig": {"url": A2A_PUSH_CALLBACK_URL},
        },
    }
    resp = requests.post(f"{A2A_BRIDGE_URL}/a2a", json=payload, timeout=70)
    resp.raise_for_status()
    data = resp.json()
    if "error" in data:
        raise RuntimeError(f"JSON-RPC error: {data['error']}")
    task = data["result"]
    _session_register(sender_wa, task)
    return task


def a2a_push_deliver(task):
    """Entrega a WhatsApp los mensajes agent del history aún no enviados."""
    task_id = task.get("id")
    sender_wa = _sender_for_task(task_id)
    if not sender_wa:
        print(f"⚠️ Push A2A para task desconocido {task_id}, ignoro")
        return

    history = task.get("history") or []
    sess = _session_get(sender_wa)
    delivered = (sess or {}).get("delivered_hist", 0)
    if delivered > len(history):
        delivered = 0  # el task se recreó (ej. bridge reiniciado): re-entregar

    estado = task.get("status", {}).get("state", "?")
    print(f"📥 Push A2A task {task_id} estado={estado} → {sender_wa} "
          f"(nuevos: {len(history) - delivered})")

    textos = []
    for m in history[delivered:]:
        if not isinstance(m, dict) or m.get("role") != "agent":
            continue
        texto = _text_from_parts(m.get("parts"))
        if texto:
            process_reply(sender_wa, texto)
            textos.append(texto)

    _session_advance(sender_wa, len(history))
    _deliver_files(sender_wa, task, textos)


# ──────────────────────────────────────────────────────────────────────────────
# Salida WhatsApp (misma lógica que el proxy directo)
# ──────────────────────────────────────────────────────────────────────────────

def process_reply(sender_wa, texto):
    """Envía el texto a WhatsApp: identificación como botón CTA interactivo,
    resto como texto. Los adjuntos (artifacts del Task) se mandan aparte con
    _deliver_files, que es la fuente estructurada que también usa /web."""
    if "/identificar?" in texto:
        m = re.search(r'(https?://\S+)', texto)
        if m:
            link = m.group(1)
            prefix = texto.split(link)[0].strip()
            send_whatsapp_cta_identificacion(sender_wa, prefix, link)
        else:
            send_whatsapp_text(sender_wa, texto)
    else:
        send_whatsapp_text(sender_wa, texto)


def send_whatsapp_cta_identificacion(sender_wa, prefix, link):
    # Botón interactivo para identificación (DIDComm)
    destinatario = sender_wa
    if destinatario.startswith("549"):
        destinatario = "54" + destinatario[3:]

    payload = {
        "messaging_product": "whatsapp",
        "to": destinatario,
        "type": "interactive",
        "interactive": {
            "type": "cta_url",
            "header": {
                "type": "text",
                "text": "Verificación de Identidad"
            },
            "body": {
                "text": prefix[:1024]
            },
            "footer": {
                "text": "Seguridad"
            },
            "action": {
                "name": "cta_url",
                "parameters": {
                    "display_text": "Identificarme",
                    "url": link
                }
            }
        }
    }

    resp = requests.post(GRAPH_URL, headers=HEADERS, json=payload, timeout=25)
    if resp.status_code >= 300:
        print("❌ Error enviando botón interactivo:", resp.status_code, resp.text)
        # fallback: enviar texto con el enlace
        send_whatsapp_text(sender_wa, f"{prefix} {link}")
    else:
        print("✅ Botón interactivo enviado correctamente")


# --- Adjuntos (documentos e imágenes) ---
#
# Los adjuntos llegan como artifacts del Task A2A (misma fuente que usa /web):
#   artifacts[] = {name, parts:[{kind:"file", file:{uri, mimeType}}, ...]}
# Se descargan, se suben con la Media Upload API y se mandan por media_id.
# WhatsApp no acepta .svg (ni como documento ni como imagen): se rasteriza a
# PNG con ImageMagick o Inkscape.

MIMES_DOCUMENTO = {
    "application/pdf": ".pdf",
    "text/plain": ".txt",
    "application/msword": ".doc",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document": ".docx",
    "application/vnd.ms-excel": ".xls",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": ".xlsx",
    "application/vnd.ms-powerpoint": ".ppt",
    "application/vnd.openxmlformats-officedocument.presentationml.presentation": ".pptx",
}
MIMES_IMAGEN = {"image/png", "image/jpeg", "image/webp"}


def _borrar(path):
    if not path:
        return
    try:
        os.remove(path)
    except OSError:
        pass


def _descargar_temporal(url):
    """Descarga la URL a static/ y devuelve (ruta, content_type|None)."""
    r = requests.get(url, timeout=30)
    if r.status_code != 200:
        print(f"❌ Error al descargar adjunto {url}: {r.status_code}")
        return None, None
    ctype = (r.headers.get("Content-Type") or "").split(";")[0].strip().lower()
    nombre = os.path.basename(url.split("?")[0]) or uuid.uuid4().hex
    path = os.path.join("static", f"{uuid.uuid4().hex}_{nombre}")
    with open(path, "wb") as f:
        f.write(r.content)
    return path, ctype


def _svg_a_png(svg_path):
    """Rasteriza un SVG a PNG. Devuelve la ruta del PNG o None."""
    png_path = os.path.splitext(svg_path)[0] + ".png"
    comandos = [
        ["convert", "-background", "white", "-density", "150", svg_path, png_path],
        ["magick", "-background", "white", "-density", "150", svg_path, png_path],
        ["inkscape", "--export-type=png", f"--export-filename={png_path}",
         "--export-background=white", svg_path],
    ]
    for cmd in comandos:
        try:
            subprocess.run(cmd, check=True, capture_output=True, timeout=60)
            if os.path.getsize(png_path) > 0:
                return png_path
        except Exception:
            continue
    return None


def _subir_media(local_path, mime):
    """Sube un archivo a la Media Upload API. Devuelve el media_id o None."""
    try:
        with open(local_path, "rb") as fh:
            res = requests.post(
                GRAPH_MEDIA_URL,
                headers={"Authorization": f"Bearer {ACCESS_TOKEN}"},
                data={"messaging_product": "whatsapp"},
                files={"file": (os.path.basename(local_path), fh, mime)},
                timeout=60,
            )
        if res.status_code >= 300:
            print("❌ Error subiendo media:", res.status_code, res.text[:300])
            return None
        return res.json().get("id")
    except Exception as e:
        print("❌ Error subiendo media:", e)
        return None


def _enviar_documento(to, local_path, mime="application/pdf", filename=None):
    media_id = _subir_media(local_path, mime)
    if not media_id:
        return False
    to_normalized = normalize_whatsapp_number(to)
    if not filename:
        filename = f"{to_normalized.replace('+', '')}.pdf"
    payload = {
        "messaging_product": "whatsapp",
        "to": to_normalized,
        "type": "document",
        "document": {"id": media_id, "filename": filename},
    }
    res = requests.post(GRAPH_URL, headers=HEADERS, json=payload, timeout=25)
    if res.status_code >= 300:
        print("❌ Error enviando documento:", res.status_code, res.text[:300])
        return False
    print(f"✅ Documento enviado (media {media_id})")
    return True


def _enviar_imagen(to, local_path, mime="image/png", caption=None):
    media_id = _subir_media(local_path, mime)
    if not media_id:
        return False
    imagen = {"id": media_id}
    if caption:
        imagen["caption"] = caption[:1024]
    payload = {
        "messaging_product": "whatsapp",
        "to": normalize_whatsapp_number(to),
        "type": "image",
        "image": imagen,
    }
    res = requests.post(GRAPH_URL, headers=HEADERS, json=payload, timeout=25)
    if res.status_code >= 300:
        print("❌ Error enviando imagen:", res.status_code, res.text[:300])
        return False
    print(f"✅ Imagen enviada (media {media_id})")
    return True


def _enviar_adjunto(sender_wa, url, mime_hint=""):
    """Descarga `url` y la manda a WhatsApp como documento o imagen.
    Devuelve True si se envió algo."""
    temporales = []
    try:
        path, ctype = _descargar_temporal(url)
        if not path:
            return False
        temporales.append(path)

        mime = ctype if "/" in (ctype or "") else ""
        if not mime or mime == "application/octet-stream":
            mime = (mime_hint or "").strip().lower()

        if mime == "image/svg+xml" or path.lower().endswith(".svg"):
            png_path = _svg_a_png(path)
            if not png_path:
                print(f"⚠️ No pude rasterizar el SVG: {url}")
                return False
            temporales.append(png_path)
            path, mime = png_path, "image/png"

        if mime in MIMES_IMAGEN:
            return _enviar_imagen(sender_wa, path, mime)
        if mime in MIMES_DOCUMENTO:
            visible = (normalize_whatsapp_number(sender_wa).replace("+", "")
                       + MIMES_DOCUMENTO[mime])
            return _enviar_documento(sender_wa, path, mime, visible)
        print(f"⚠️ Tipo no soportado por WhatsApp ({mime or 'desconocido'}): {url}")
        return False
    except Exception as e:
        print("❌ Error enviando adjunto:", e)
        return False
    finally:
        for p in temporales:
            _borrar(p)


def _deliver_files(sender_wa, task, textos=()):
    """Manda a WhatsApp los adjuntos del Task que todavía no se enviaron.
    Si el Task no trae artifacts, cae al link .pdf que venga en el texto."""
    arts = task.get("artifacts") or []
    with _sessions_lock:
        already = (_sessions.get(sender_wa) or {}).get("delivered_arts", 0)
    if already > len(arts):
        already = 0  # el task se recreó (ej. bridge reiniciado): re-entregar

    enviados = 0
    for art in arts[already:]:
        for part in (art or {}).get("parts", []):
            file_ = part.get("file") or {}
            uri = file_.get("uri") or ""
            # Los data: URI son del QR inline que arma el bridge para /web.
            if not isinstance(uri, str) or not uri.startswith(("http://", "https://")):
                continue
            if _enviar_adjunto(sender_wa, uri, file_.get("mimeType") or ""):
                enviados += 1

    with _sessions_lock:
        if sender_wa in _sessions:
            _sessions[sender_wa]["delivered_arts"] = len(arts)

    # Fallback: sin artifacts, mantener el comportamiento viejo (link .pdf).
    if not arts and not already:
        for texto in textos:
            pdf_link = extraer_link_pdf(texto)
            if pdf_link and send_whatsapp_pdf(sender_wa, pdf_link):
                enviados += 1
                break
    return enviados


def send_whatsapp_pdf(to, pdf_url, filename=None):
    """Descarga el PDF de la URL y lo manda como documento (por media_id)."""
    path = None
    try:
        path, _ = _descargar_temporal(pdf_url)
        if not path:
            return False
        return _enviar_documento(to, path, "application/pdf", filename)
    except Exception as e:
        print("❌ Error en send_whatsapp_pdf:", e)
        return False
    finally:
        _borrar(path)


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
                model="gpt-transcribe",
                file=f
            )
        return transcription.text
    finally:
        try:
            os.remove(temp_path)
        except FileNotFoundError:
            pass


@app.route("/identificar")
def identificar():
    oob = request.args.get("oob")
    vp = request.args.get("vp")

    if vp:
        didcomm_link = vp
    elif oob:
        didcomm_link = f"didcomm://?_oob={oob}"
    else:
        return "Missing OOB", 400

    # Para Android usamos intent:// (los navegadores embebidos de WhatsApp/Facebook
    # bloquean la navegación por custom schemes, pero sí procesan intents)
    scheme = didcomm_link.split("://", 1)[0]
    data = didcomm_link.split("://", 1)[1]
    fallback = request.url
    intent_link = f"intent://{data}#Intent;scheme={scheme};S.browser_fallback_url={quote(fallback, safe='')};end"

    link_scheme_js = json.dumps(didcomm_link)
    link_intent_js = json.dumps(intent_link)

    # QR inline: la wallet solo abre los pedidos desde su scanner interno
    # (no registra handler para el esquema), asi que en PC se escanea con el telefono
    qr = qrcode.QRCode(error_correction=1, border=4, image_factory=SvgPathImage)
    qr.add_data(didcomm_link)
    qr.make(fit=True)
    buf = io.BytesIO()
    qr.make_image().save(buf)
    qr_svg = buf.getvalue().decode().split("?>", 1)[1].strip()

    html = f"""
    <html>
    <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Identificación</title>
        <style>
            #qrbox svg {{ width: 280px; height: 280px; display: block; margin: 0 auto; }}
            #qrCaption {{ color: #555; font-size: 14px; max-width: 360px; margin: 10px auto 0; }}
        </style>
    </head>
    <body style="font-family:sans-serif;text-align:center;padding-top:40px">
        <h2>Identificación con credencial digital</h2>
        <p id="estado" style="color:#555">Abriendo la aplicación de identidad...</p>
        <p style="margin:24px 0">
            <a id="abrir" href="{didcomm_link}"
               style="display:inline-block;padding:14px 28px;background:#25D366;color:#fff;border-radius:8px;text-decoration:none;font-size:18px">
               Abrir identificación
            </a>
        </p>
        <p style="margin:16px 0">
            <button onclick="copiar()"
                    style="padding:10px 18px;border-radius:8px;border:1px solid #ccc;background:#f5f5f5;font-size:15px">
                Copiar enlace de verificación
            </button>
        </p>
        <div id="qrbox" style="background:#fff;padding:12px;border-radius:8px;display:inline-block;margin-top:8px">
            {qr_svg}
        </div>
        <p id="qrCaption"></p>
        <p id="ayuda" style="display:none;color:#777;font-size:14px;max-width:340px;margin:0 auto">
            Si la app no se abre: copiá el enlace, abrí Chrome (o Safari) y pegalo en la barra
            de direcciones. Eso va a abrir la aplicación de identidad.
        </p>
        <script>
            var LINK_SCHEME = {link_scheme_js};
            var LINK_INTENT = {link_intent_js};
            var ua = navigator.userAgent || "";
            var esAndroid = /Android/.test(ua);
            var esMobile = /Android|iPhone|iPad|Mobile/i.test(ua);
            var esInApp = /FBAN|FBAV|Instagram|WhatsApp\\/|Line\\/|EmbeddedBrowser/.test(ua);
            var link = esAndroid ? LINK_INTENT : LINK_SCHEME;
            document.getElementById("abrir").href = link;

            function copiar() {{
                if (navigator.clipboard && navigator.clipboard.writeText) {{
                    navigator.clipboard.writeText(LINK_SCHEME);
                }} else {{
                    var i = document.createElement("input");
                    i.value = LINK_SCHEME;
                    document.body.appendChild(i);
                    i.select();
                    document.execCommand("copy");
                    i.remove();
                }}
                document.getElementById("estado").textContent =
                    "Enlace copiado. Abrilo en Chrome y se abrirá la app de identidad.";
            }}

            if (esMobile) {{
                document.getElementById("qrCaption").textContent =
                    "Si no se abre la app: escaneá este QR con la app de identidad " +
                    "(desde otro dispositivo) o abrí esta página desde WhatsApp en una PC.";
                if (!esInApp) {{
                    setTimeout(function() {{ window.location.href = link; }}, 600);
                }} else {{
                    document.getElementById("estado").textContent =
                        "Tocá el botón verde para abrir la app de identidad.";
                    document.getElementById("ayuda").style.display = "block";
                }}
            }} else {{
                document.getElementById("estado").textContent =
                    "Escaneá este QR con la app de identidad de tu teléfono.";
            }}
        </script>
    </body>
    </html>
    """

    return html

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


# --- Push asíncrono desde el bridge A2A ---

@app.route("/a2a/push", methods=["POST"])
def a2a_push():
    """El bridge A2A notifica acá los updates asíncronos de un Task
    (resultados Kafka / callback DIDComm). Body: Task A2A completo."""
    task = request.get_json(force=True, silent=True)
    if not isinstance(task, dict) or "id" not in task:
        return jsonify({"status": "error", "message": "Task inválido"}), 400

    try:
        a2a_push_deliver(task)
    except Exception as e:
        print("❌ Error procesando push A2A:", e)
    return jsonify({"status": "ok"}), 200


@app.route("/identificacion_usuario", methods=["POST"])
@app.route("/i", methods=["POST"])
def identificacion_usuario():
    data = request.json
    try:
        res = requests.post(IDENT_PROLOG_URL, json=data, timeout=10)
        return jsonify(res.json()), res.status_code
    except Exception as e:
        print(f"❌ Error reenviando identificación: {e}")
        return jsonify({"status":"error","message":"Error reenviando identificación"}), 500

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

        if msg_type == "text":
            text = msg["text"]["body"]
        elif msg_type == "button":
            text = msg["button"]["text"]
        elif msg_type == "interactive":
            # Las respuestas a botones interactivos (ej. cta_url) no traen texto
            pass
        elif msg_type in ["audio", "voice"]:
            media_id = msg[msg_type]["id"]
            media_url = get_media_url(media_id)
            audio_bytes = download_media(media_url)
            text = transcribe_audio(audio_bytes)
            print(f"📝 Transcripción: {text}")

        if not text:
            send_whatsapp_text(sender_wa, "Recibí tu mensaje 👍 (tipo no soportado).")
            return jsonify({"status": "ok"}), 200

        print(f"👤 {sender_wa}: {text}")

        # --- Pasar a Chita vía A2A (message/send al bridge) ---
        try:
            task = a2a_send_message(sender_wa, text)
        except Exception as e:
            print("❌ Error A2A:", e)
            send_whatsapp_text(sender_wa, "⚠️ Error al conectar con el motor de diálogo.")
            return jsonify({"status": "ok"}), 200

        # Respuesta síncrona: el último mensaje agent del Task
        agent_text = _text_from_parts((task.get("status", {}).get("message") or {}).get("parts"))
        if not agent_text:
            agent_text = "(sin respuesta del agente)"

        print(f"🤖 Chita [{task.get('status', {}).get('state', '?')}]: {agent_text}")
        process_reply(sender_wa, agent_text)
        _deliver_files(sender_wa, task, [agent_text])

        return jsonify({"status": "ok"}), 200

    except Exception as e:
        print("❌ Error parseando evento:", e)
        return jsonify({"status": "error"}), 200


@app.route("/health", methods=["GET"])
def health():
    with _sessions_lock:
        n = len(_sessions)
    return jsonify({"status": "ok", "sessions": n}), 200


if __name__ == "__main__":
    os.makedirs("static", exist_ok=True)
    print(f"🚀 Flask WhatsApp ↔ A2A en http://localhost:{A2A_FLASK_PORT}")
    print(f"   Bridge A2A:  {A2A_BRIDGE_URL}")
    print(f"   Push URL:    {A2A_PUSH_CALLBACK_URL}")
    app.run(host="0.0.0.0", port=A2A_FLASK_PORT)
