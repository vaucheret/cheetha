"""
chita_a2a_server.py — Bridge A2A para el chatbot Chita.

Expone el chatbot Prolog (http://localhost:8000) como un agente A2A estándar
(protocolo A2A v0.2.6, JSON-RPC 2.0 sobre HTTP). Permite que otros agentes
(municipios, Google ADK, LangGraph, etc.) deleguen tareas conversacionales en Chita.

Endpoints:
  GET  /.well-known/agent.json     → Agent Card estándar A2A
  POST /a2a                         → despachador JSON-RPC (message/send, tasks/get)
  POST /internal/update_task        → interno: Prolog notifica resultados asíncronos (Kafka/DIDComm)

Puerto por defecto: 8001.  Variable de entorno A2A_BRIDGE_URL para override.

Dependencias: flask, requests (ya usadas por el proyecto). No requiere a2a-python.
"""
import os
import json
import uuid
import time
import threading
from flask import Flask, request, jsonify, send_from_directory
import requests

app = Flask(__name__)

PROLOG_BASE_URL = os.getenv("PROLOG_BASE_URL", "http://localhost:8000")
CHAT_A2A_URL = f"{PROLOG_BASE_URL}/chat_a2a"
AGENT_CARD_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "agent.json")

# Store in-memory de Tasks A2A: {task_id: Task}
# Thread-safe con lock. Suficiente para MVP; persistencia opcional después.
_tasks_store = {}
_tasks_lock = threading.Lock()

# Mapeo user_id (contextId) → task_id activo, para asociar updates asíncronos
_context_to_task = {}


def _now_iso():
    import datetime
    return datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")


def _load_agent_card():
    """Carga la Agent Card desde agent.json, inyectando la URL real del bridge."""
    with open(AGENT_CARD_PATH, "r", encoding="utf-8") as f:
        card = json.load(f)
    # La url la resolvemos en runtime: preferimos A2A_BRIDGE_URL, sino host del request
    bridge_url = os.getenv("A2A_BRIDGE_URL")
    if bridge_url:
        card["url"] = f"{bridge_url}/a2a"
    return card


def _text_from_parts(parts):
    """Extrae texto de una lista de Parts A2A (TextPart). Concatena todos los text."""
    texts = []
    for p in parts or []:
        if p.get("kind") == "text" or "text" in p:
            texts.append(p.get("text", ""))
    return "\n".join(texts) if texts else ""


def _make_message(role, text, task_id=None, context_id=None):
    """Construye un objeto Message A2A con un TextPart."""
    return {
        "role": role,
        "parts": [{"kind": "text", "text": text}],
        "messageId": str(uuid.uuid4()),
        "taskId": task_id,
        "contextId": context_id,
        "kind": "message",
    }


def _make_task(task_id, context_id, state, message_text=None, artifact=None, history=None):
    """Construye un objeto Task A2A."""
    task = {
        "id": task_id,
        "contextId": context_id,
        "status": {
            "state": state,
            "timestamp": _now_iso(),
        },
        "history": history or [],
        "kind": "task",
    }
    if message_text is not None:
        task["status"]["message"] = _make_message(
            "agent", message_text, task_id=task_id, context_id=context_id
        )
    if artifact is not None:
        task["artifacts"] = [artifact] if not isinstance(artifact, list) else artifact
    return task


def _store_task(task):
    with _tasks_lock:
        _tasks_store[task["id"]] = task
        _context_to_task[task["contextId"]] = task["id"]


def _get_task(task_id):
    with _tasks_lock:
        return _tasks_store.get(task_id)


def _update_task_state(task_id, state, message_text=None, artifact=None):
    """Actualiza un task existente (usado por /internal/update_task y por message/send)."""
    with _tasks_lock:
        task = _tasks_store.get(task_id)
        if task is None:
            return None
        task["status"]["state"] = state
        task["status"]["timestamp"] = _now_iso()
        if message_text is not None:
            agent_msg = _make_message("agent", message_text, task_id=task_id, context_id=task["contextId"])
            task["status"]["message"] = agent_msg
            task["history"].append(agent_msg)
        if artifact is not None:
            arts = task.get("artifacts", [])
            arts.append(artifact) if not isinstance(artifact, list) else arts.extend(artifact)
            task["artifacts"] = arts
        return task


# ──────────────────────────────────────────────────────────────────────────────
# Agent Card (well-known)
# ──────────────────────────────────────────────────────────────────────────────

@app.route("/.well-known/agent.json", methods=["GET"])
def agent_card():
    card = _load_agent_card()
    # Si no hay A2A_BRIDGE_URL, usar el host del request
    if "url" not in card or not os.getenv("A2A_BRIDGE_URL"):
        card["url"] = f"{request.host_url.rstrip('/')}/a2a"
    return jsonify(card), 200


# ──────────────────────────────────────────────────────────────────────────────
# Endpoint interno: Prolog notifica resultados asíncronos (Kafka/DIDComm)
# ──────────────────────────────────────────────────────────────────────────────

@app.route("/internal/update_task", methods=["POST"])
def internal_update_task():
    """Prolog llama acá cuando llega un resultado Kafka/DIDComm para una sesión A2A.
    Body: {task_id, estado, texto, artifact?}
    """
    data = request.get_json(force=True, silent=True) or {}
    task_id = data.get("task_id")
    estado = data.get("estado", "completed")
    texto = data.get("texto", "")
    artifact = data.get("artifact")

    if not task_id:
        return jsonify({"status": "error", "message": "task_id requerido"}), 400

    task = _update_task_state(task_id, estado, message_text=texto, artifact=artifact)
    if task is None:
        return jsonify({"status": "error", "message": f"task {task_id} no encontrado"}), 404

    print(f"[A2A-internal] task {task_id} → {estado}: {texto[:80]}")
    return jsonify({"status": "ok"}), 200


# ──────────────────────────────────────────────────────────────────────────────
# Despachador JSON-RPC 2.0 (/a2a)
# ──────────────────────────────────────────────────────────────────────────────

@app.route("/a2a", methods=["POST"])
def a2a_dispatch():
    """Despachador JSON-RPC 2.0. Métodos soportados:
      - message/send : envía un mensaje del usuario al agente Chita, devuelve Task
      - tasks/get    : recupera el estado actual de un Task (para polling asíncrono)
    """
    payload = request.get_json(force=True, silent=True)
    if payload is None or "method" not in payload:
        return _jsonrpc_error(None, -32600, "Invalid Request")

    req_id = payload.get("id")
    method = payload.get("method")
    params = payload.get("params", {}) or {}

    try:
        if method == "message/send":
            result = _handle_message_send(params)
            return _jsonrpc_result(req_id, result)
        elif method == "tasks/get":
            result = _handle_tasks_get(params)
            return _jsonrpc_result(req_id, result)
        else:
            return _jsonrpc_error(req_id, -32601, f"Method not found: {method}")
    except A2AError as e:
        return _jsonrpc_error(req_id, e.code, e.message)
    except Exception as e:
        print(f"[A2A] error despachando {method}: {e}")
        return _jsonrpc_error(req_id, -32603, f"Internal error: {e}")


def _handle_message_send(params):
    """message/send: envía un mensaje del usuario a Chita y devuelve el Task actualizado.
    params: {message: {role, parts, messageId, taskId?, contextId?}}
    """
    msg = params.get("message")
    if not msg or "parts" not in msg:
        raise A2AError(-32602, "message.parts es requerido")

    user_text = _text_from_parts(msg.get("parts"))
    if not user_text:
        raise A2AError(-32602, "No se encontró texto en parts")

    context_id = msg.get("contextId") or str(uuid.uuid4())
    task_id = msg.get("taskId")

    # Si no hay task_id, crear nuevo task o reutilizar por context_id
    if not task_id:
        with _tasks_lock:
            task_id = _context_to_task.get(context_id) or str(uuid.uuid4())

    # Registrar user_id = context_id para que Prolog mantenga sesión
    user_id = context_id

    # Llamar a Prolog /chat_a2a
    prolog_payload = {
        "message": {"user_id": user_id, "text": user_text},
        "task_id": task_id,
        "context_id": context_id,
    }
    try:
        resp = requests.post(CHAT_A2A_URL, json=prolog_payload, timeout=65)
        resp.raise_for_status()
        data = resp.json()
    except requests.RequestException as e:
        raise A2AError(-32603, f"Error llamando a Prolog: {e}")

    respuesta = data.get("respuesta", "")
    estado = data.get("estado", "input-required")
    artifact = data.get("artifact")

    # Construir/actualizar Task
    existing = _get_task(task_id)
    user_msg = _make_message("user", user_text, task_id=task_id, context_id=context_id)
    if existing:
        with _tasks_lock:
            existing["history"].append(user_msg)
            existing["status"]["state"] = estado
            existing["status"]["timestamp"] = _now_iso()
            agent_msg = _make_message("agent", respuesta, task_id=task_id, context_id=context_id)
            existing["status"]["message"] = agent_msg
            existing["history"].append(agent_msg)
            if artifact:
                arts = existing.get("artifacts", [])
                arts.append(artifact)
                existing["artifacts"] = arts
        task = existing
    else:
        agent_msg = _make_message("agent", respuesta, task_id=task_id, context_id=context_id)
        task = _make_task(
            task_id, context_id, estado,
            message_text=respuesta,
            artifact=artifact,
            history=[user_msg, agent_msg],
        )
        _store_task(task)

    return task


def _handle_tasks_get(params):
    """tasks/get: recupera un Task por id. params: {id: task_id}"""
    task_id = params.get("id")
    if not task_id:
        raise A2AError(-32602, "id es requerido")
    task = _get_task(task_id)
    if task is None:
        raise A2AError(-32001, f"Task no encontrado: {task_id}")
    return task


# ──────────────────────────────────────────────────────────────────────────────
# Helpers JSON-RPC
# ──────────────────────────────────────────────────────────────────────────────

class A2AError(Exception):
    def __init__(self, code, message):
        self.code = code
        self.message = message
        super().__init__(f"[{code}] {message}")


def _jsonrpc_result(req_id, result):
    return jsonify({
        "jsonrpc": "2.0",
        "id": req_id,
        "result": result,
    }), 200


def _jsonrpc_error(req_id, code, message):
    return jsonify({
        "jsonrpc": "2.0",
        "id": req_id,
        "error": {"code": code, "message": message},
    }), 200


# ──────────────────────────────────────────────────────────────────────────────
# Interfaz web de testing (/web)
# ──────────────────────────────────────────────────────────────────────────────

@app.route("/web", methods=["GET"])
def web_tester():
    """Sirve una interfaz web HTML+JS para testing del cliente A2A desde el browser.
    Accessible desde cualquier dispositivo vía ngrok. Sin dependencias externas.
    """
    return WEB_TESTER_HTML, 200, {"Content-Type": "text/html; charset=utf-8"}


WEB_TESTER_HTML = r"""<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>VERA A2A Tester</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
         background: #f0f2f5; color: #1a1a1a; height: 100vh; display: flex; flex-direction: column; }
  header { background: #1a73e8; color: white; padding: 12px 20px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
  header h1 { font-size: 18px; display: flex; align-items: center; gap: 8px; }
  .config-bar { background: #fff; padding: 10px 20px; border-bottom: 1px solid #ddd; display: flex; gap: 12px; align-items: center; flex-wrap: wrap; }
  .config-bar label { font-size: 13px; color: #555; font-weight: 600; }
  .config-bar input[type=text] { border: 1px solid #ccc; border-radius: 6px; padding: 6px 10px; font-size: 13px; width: 280px; }
  .config-bar button, .config-bar select { border: 1px solid #ccc; border-radius: 6px; padding: 6px 12px; font-size: 13px; cursor: pointer; background: #fff; }
  .config-bar button:hover { background: #f5f5f5; }
  .agent-info { font-size: 12px; color: #666; padding: 6px 20px; background: #fafafa; border-bottom: 1px solid #eee; }
  .agent-info b { color: #333; }
  #chat { flex: 1; overflow-y: auto; padding: 20px; display: flex; flex-direction: column; gap: 10px; }
  .msg { max-width: 75%; padding: 10px 14px; border-radius: 12px; font-size: 14px; line-height: 1.5; word-wrap: break-word; }
  .msg.user { align-self: flex-end; background: #1a73e8; color: white; }
  .msg.agent { align-self: flex-start; background: white; border: 1px solid #e0e0e0; }
  .msg .state { display: inline-block; font-size: 11px; padding: 2px 8px; border-radius: 10px; margin-left: 6px; font-weight: 600; }
  .state-input-required { background: #e6f4ea; color: #137333; }
  .state-working { background: #fef7e0; color: #b06000; }
  .state-completed { background: #e8f0fe; color: #1967d2; }
  .state-auth-required { background: #fce8e6; color: #c5221f; }
  .state-canceled, .state-failed { background: #fce8e6; color: #c5221f; }
  .artifact { align-self: flex-start; background: #f3e8fd; border: 1px solid #d9aefb; border-radius: 8px; padding: 8px 12px; font-size: 13px; margin-top: -4px; }
  .artifact a { color: #8430ce; text-decoration: none; font-weight: 600; }
  .polling { align-self: center; color: #b06000; font-size: 12px; font-style: italic; }
  .input-bar { background: #fff; padding: 12px 20px; border-top: 1px solid #ddd; display: flex; gap: 10px; }
  .input-bar input[type=text] { flex: 1; border: 1px solid #ccc; border-radius: 8px; padding: 10px 14px; font-size: 14px; }
  .input-bar button { background: #1a73e8; color: white; border: none; border-radius: 8px; padding: 10px 20px; font-size: 14px; cursor: pointer; font-weight: 600; }
  .input-bar button:disabled { background: #ccc; cursor: not-allowed; }
  .status-line { font-size: 11px; color: #999; padding: 0 20px 8px; }
</style>
</head>
<body>

<header>
  <h1>🏛️ Vera A2A Tester</h1>
</header>

<div class="config-bar">
  <label>Bridge URL:</label>
  <input type="text" id="bridgeUrl" value="">
  <button onclick="fetchAgentCard()">🔌 Conectar</button>
  <button onclick="resetSession()">🔄 Nueva conversación</button>
  <select id="scriptSelect" onchange="runScript()">
    <option value="">▶️ Reproducir script...</option>
    <option value="renovar_dni">Renovar DNI (4 turnos)</option>
  </select>
</div>

<div class="agent-info" id="agentInfo">Sin conectar. Hacé clic en "Conectar".</div>

<div id="chat"></div>

<div class="status-line" id="statusLine"></div>

<div class="input-bar">
  <input type="text" id="msgInput" placeholder="Mensaje del ciudadano..." onkeypress="if(event.key==='Enter')sendMessage()" disabled>
  <button id="sendBtn" onclick="sendMessage()" disabled>Enviar</button>
</div>

<script>
let bridgeUrl = "";
let contextId = null;
let taskId = null;
let polling = false;

const SCRIPTS = {
  renovar_dni: ["hola quiero renovar mi dni", "si", "12345678", "15/03/1990"]
};

window.onload = function() {
  document.getElementById("bridgeUrl").value = window.location.origin;
};

function setStatus(text) {
  document.getElementById("statusLine").textContent = text;
}

function escapeHtml(text) {
  const div = document.createElement("div");
  div.textContent = text;
  let html = div.innerHTML.replace(/\n/g, "<br>");
  html = html.replace(/(https?:\/\/[^\s<]+)/g, '<a href="$1" target="_blank" rel="noopener">$1</a>');
  return html;
}

function addMsg(role, text, state) {
  const chat = document.getElementById("chat");
  const div = document.createElement("div");
  div.className = "msg " + (role === "user" ? "user" : "agent");
  let html = escapeHtml(text);
  if (state) {
    const cls = "state state-" + state;
    html += ' <span class="' + cls + '">' + state + '</span>';
  }
  div.innerHTML = html;
  chat.appendChild(div);
  chat.scrollTop = chat.scrollHeight;
}

function addArtifact(artifact) {
  const chat = document.getElementById("chat");
  const div = document.createElement("div");
  div.className = "artifact";
  let name = artifact.name || "artifact";
  let parts = artifact.parts || [];
  let textParts = parts.filter(p => p.kind === "text").map(p => p.text).join(" ");
  let links = parts.filter(p => p.kind === "file" && p.file && p.file.uri).map(p => p.file.uri);
  let html = "📦 " + escapeHtml(name);
  if (textParts) html += ": " + escapeHtml(textParts);
  if (links.length) html += ' <a href="' + links[0] + '" target="_blank">descargar</a>';
  div.innerHTML = html;
  chat.appendChild(div);
  chat.scrollTop = chat.scrollHeight;
}

function addPolling(text) {
  const chat = document.getElementById("chat");
  const div = document.createElement("div");
  div.className = "polling";
  div.id = "pollingIndicator";
  div.textContent = text;
  chat.appendChild(div);
  chat.scrollTop = chat.scrollHeight;
}

function removePolling() {
  const el = document.getElementById("pollingIndicator");
  if (el) el.remove();
}

async function fetchAgentCard() {
  bridgeUrl = document.getElementById("bridgeUrl").value.replace(/\/$/, "");
  try {
    const r = await fetch(bridgeUrl + "/.well-known/agent.json");
    if (!r.ok) throw new Error("HTTP " + r.status);
    const card = await r.json();
    const skills = (card.skills || []).map(s => s.name).join(", ");
    document.getElementById("agentInfo").innerHTML =
      '<b>' + card.name + '</b> · v' + card.version + ' · Skills: ' + skills + ' · URL: ' + card.url;
    document.getElementById("msgInput").disabled = false;
    document.getElementById("sendBtn").disabled = false;
    setStatus("Conectado. Task: " + (taskId || "ninguno"));
    addMsg("agent", "✅ Conectado a " + card.name + ". Hola, te puedo asistir en todo tipo de trámites. Escribí un mensaje para iniciar.");
  } catch (e) {
    document.getElementById("agentInfo").textContent = "❌ Error conectando: " + e.message;
    setStatus("");
  }
}

async function sendMessage(text) {
  if (!bridgeUrl) { alert("Conectá primero"); return; }
  if (!text) text = document.getElementById("msgInput").value.trim();
  if (!text) return;
  document.getElementById("msgInput").value = "";
  addMsg("user", text);

  const msg = { role: "user", parts: [{kind: "text", text: text}], messageId: crypto.randomUUID() };
  if (contextId) msg.contextId = contextId;
  if (taskId) msg.taskId = taskId;

  const payload = { jsonrpc: "2.0", id: crypto.randomUUID(), method: "message/send", params: { message: msg } };
  setStatus("Enviando...");
  try {
    const r = await fetch(bridgeUrl + "/a2a", {
      method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify(payload)
    });
    const resp = await r.json();
    if (resp.error) { addMsg("agent", "❌ Error: " + resp.error.message); setStatus(""); return; }
    const task = resp.result;
    taskId = task.id;
    contextId = task.contextId;
    handleTaskUpdate(task);
  } catch (e) {
    addMsg("agent", "❌ Error de red: " + e.message);
    setStatus("");
  }
}

function handleTaskUpdate(task) {
  const state = task.status.state;
  const msg = task.status.message;
  let text = "(sin mensaje)";
  if (msg && msg.parts) text = msg.parts.filter(p => p.kind === "text").map(p => p.text).join(" ");
  addMsg("agent", text, state);
  setStatus("Estado: " + state + " | Task: " + task.id);

  if (task.artifacts) {
    task.artifacts.forEach(a => addArtifact(a));
  }

  if (state === "working" && !polling) {
    pollTask();
  }
}

async function pollTask() {
  polling = true;
  addPolling("⏳ Trámite en proceso. Haciendo polling cada 2s...");
  for (let i = 0; i < 30; i++) {
    await new Promise(r => setTimeout(r, 2000));
    const payload = { jsonrpc: "2.0", id: crypto.randomUUID(), method: "tasks/get", params: { id: taskId } };
    try {
      const r = await fetch(bridgeUrl + "/a2a", {
        method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify(payload)
      });
      const resp = await r.json();
      if (resp.error) continue;
      const task = resp.result;
      const state = task.status.state;
      if (state !== "working") {
        removePolling();
        handleTaskUpdate(task);
        polling = false;
        return;
      }
    } catch (e) { break; }
  }
  removePolling();
  addMsg("agent", "⚠️ Timeout esperando resultado asíncrono.", "failed");
  polling = false;
  setStatus("");
}

function resetSession() {
  contextId = null;
  taskId = null;
  polling = false;
  document.getElementById("chat").innerHTML = "";
  setStatus("Sesión reiniciada.");
}

async function runScript() {
  const name = document.getElementById("scriptSelect").value;
  if (!name) return;
  document.getElementById("scriptSelect").value = "";
  const lines = SCRIPTS[name] || [];
  if (!lines.length) return;
  resetSession();
  for (const line of lines) {
    if (polling) await new Promise(r => setTimeout(r, 1000));
    await sendMessage(line);
    await new Promise(r => setTimeout(r, 500));
    if (polling) {
      while (polling) await new Promise(r => setTimeout(r, 500));
    }
  }
}
</script>
</body>
</html>
"""


# ──────────────────────────────────────────────────────────────────────────────
# Health
# ──────────────────────────────────────────────────────────────────────────────

@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "ok", "tasks": len(_tasks_store)}), 200


if __name__ == "__main__":
    port = int(os.getenv("A2A_BRIDGE_PORT", "8001"))
    print(f"🚀 Chita A2A Bridge en http://localhost:{port}")
    print(f"   Agent Card:  http://localhost:{port}/.well-known/agent.json")
    print(f"   JSON-RPC:    http://localhost:{port}/a2a")
    print(f"   Web Tester:  http://localhost:{port}/web")
    print(f"   Prolog:      {CHAT_A2A_URL}")
    app.run(host="0.0.0.0", port=port)
