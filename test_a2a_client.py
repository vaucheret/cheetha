#!/usr/bin/env python3
"""
test_a2a_client.py — Agente municipio ficticio (cliente A2A).

Simula un agente de un municipio que delega consultas de trámites en Chita
vía el protocolo A2A. Demuestra cómo cualquier agente externo puede usar
a Chita como subagente sin pasar por WhatsApp.

Uso:
  python3 test_a2a_client.py                          # modo interactivo (stdin)
  python3 test_a2a_client.py --script renovar_dni.txt # reproduce diálogo pregrabado
  python3 test_a2a_client.py --url http://host:8001   # bridge A2A remoto

Dependencias: requests (ya usada por el proyecto). No requiere a2a-python.
"""
import argparse
import json
import sys
import time
import uuid
import requests


class ChitaA2AClient:
    """Cliente A2A que habla JSON-RPC 2.0 con el bridge de Chita."""

    def __init__(self, bridge_url):
        self.bridge_url = bridge_url.rstrip("/")
        self.agent_card = None
        self.context_id = None
        self.task_id = None

    def fetch_agent_card(self):
        """Descubre las capacidades de Chita vía Agent Card."""
        r = requests.get(f"{self.bridge_url}/.well-known/agent.json", timeout=10)
        r.raise_for_status()
        self.agent_card = r.json()
        return self.agent_card

    def send_message(self, text):
        """message/send: envía un turno del usuario y devuelve el Task actualizado.
        A2A spec §7.1. Mantiene contextId y taskId entre turnos (multi-turno).
        """
        msg = {
            "role": "user",
            "parts": [{"kind": "text", "text": text}],
            "messageId": str(uuid.uuid4()),
        }
        if self.context_id:
            msg["contextId"] = self.context_id
        if self.task_id:
            msg["taskId"] = self.task_id

        payload = {
            "jsonrpc": "2.0",
            "id": str(uuid.uuid4()),
            "method": "message/send",
            "params": {"message": msg},
        }
        r = requests.post(
            f"{self.bridge_url}/a2a",
            json=payload,
            headers={"Content-Type": "application/json"},
            timeout=70,
        )
        r.raise_for_status()
        resp = r.json()
        if "error" in resp:
            raise RuntimeError(f"JSON-RPC error: {resp['error']}")

        task = resp["result"]
        self.task_id = task["id"]
        self.context_id = task["contextId"]
        return task

    def get_task(self, task_id=None):
        """tasks/get: recupera el estado actual de un Task (polling asíncrono).
        A2A spec §7.3.
        """
        tid = task_id or self.task_id
        payload = {
            "jsonrpc": "2.0",
            "id": str(uuid.uuid4()),
            "method": "tasks/get",
            "params": {"id": tid},
        }
        r = requests.post(
            f"{self.bridge_url}/a2a",
            json=payload,
            headers={"Content-Type": "application/json"},
            timeout=30,
        )
        r.raise_for_status()
        resp = r.json()
        if "error" in resp:
            raise RuntimeError(f"JSON-RPC error: {resp['error']}")
        return resp["result"]

    @staticmethod
    def extract_text(task):
        """Extrae el texto de la respuesta del agente desde el Task."""
        status = task.get("status", {})
        msg = status.get("message")
        if msg and msg.get("parts"):
            return " ".join(p.get("text", "") for p in msg["parts"] if p.get("kind") == "text")
        return "(sin mensaje)"

    @staticmethod
    def get_state(task):
        return task.get("status", {}).get("state", "unknown")


def run_interactive(client):
    """Modo interactivo: el usuario teclea los mensajes del ciudadano."""
    print("=" * 60)
    print("🏛️  Agente Municipio Ficticio — Cliente A2A de Chita")
    print("=" * 60)

    # 1. Descubrir Chita
    print("\n📡 Descubriendo Chita vía Agent Card...")
    card = client.fetch_agent_card()
    print(f"   Nombre: {card.get('name')}")
    print(f"   Skills: {[s['name'] for s in card.get('skills', [])]}")
    print(f"   URL:    {card.get('url')}")

    print("\n💬 Escribí el mensaje del ciudadano (Ctrl+D para salir):\n")

    while True:
        try:
            user_input = input("Ciudadano> ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\n👋 Fin de la conversación.")
            break
        if not user_input:
            continue

        task = client.send_message(user_input)
        state = client.get_state(task)
        respuesta = client.extract_text(task)
        print(f"  Chita [{state}]: {respuesta}\n")

        # Si está working, hacer polling hasta que termine
        if state == "working":
            print("  ⏳ Trámite en proceso. Haciendo polling...")
            _poll_until_done(client)

        if state in ("completed", "canceled", "failed"):
            print("  ✅ Conversación finalizada. Iniciá una nueva escribiendo otro mensaje.\n")


def run_script(client, script_path):
    """Reproduce un diálogo pregrabado desde un archivo de texto.
    Formato: una línea por turno del ciudadano, comentarios con #.
    """
    print("=" * 60)
    print(f"🏛️  Agente Municipio Ficticio — Script: {script_path}")
    print("=" * 60)

    # Descubrir Chita
    print("\n📡 Descubriendo Chita vía Agent Card...")
    card = client.fetch_agent_card()
    print(f"   Nombre: {card.get('name')}")

    with open(script_path, "r", encoding="utf-8") as f:
        lines = [l.strip() for l in f if l.strip() and not l.strip().startswith("#")]

    print(f"\n📜 Reproduciendo {len(lines)} turnos:\n")

    for i, user_input in enumerate(lines, 1):
        print(f"--- Turno {i} ---")
        print(f"Ciudadano> {user_input}")
        task = client.send_message(user_input)
        state = client.get_state(task)
        respuesta = client.extract_text(task)
        print(f"  Chita [{state}]: {respuesta}\n")

        if state == "working":
            print("  ⏳ Trámite en proceso. Haciendo polling...")
            _poll_until_done(client)

        if state in ("completed", "canceled", "failed"):
            print(f"  ✅ Task finalizado con estado: {state}")
            break
        time.sleep(0.5)

    # Mostrar artifacts si hay
    task = client.get_task()
    artifacts = task.get("artifacts", [])
    if artifacts:
        print(f"\n📦 Artifacts generados: {len(artifacts)}")
        for a in artifacts:
            print(f"   - {a}")


def _poll_until_done(client, max_attempts=30, interval=2):
    """Hace polling con tasks/get hasta que el task llegue a estado terminal."""
    for _ in range(max_attempts):
        time.sleep(interval)
        task = client.get_task()
        state = client.get_state(task)
        if state != "working":
            respuesta = client.extract_text(task)
            print(f"  Chita [{state}]: {respuesta}")
            return
        print(f"  ...sigue working")
    print("  ⚠️ Timeout esperando resultado asíncrono.")


def main():
    parser = argparse.ArgumentParser(description="Cliente A2A de Chita (agente municipio ficticio)")
    parser.add_argument("--url", default="http://localhost:8001",
                        help="URL del bridge A2A de Chita (default: http://localhost:8001)")
    parser.add_argument("--script", default=None,
                        help="Archivo con diálogo pregrabado (una línea por turno, # = comentario)")
    args = parser.parse_args()

    client = ChitaA2AClient(args.url)

    try:
        if args.script:
            run_script(client, args.script)
        else:
            run_interactive(client)
    except requests.ConnectionError:
        print(f"\n❌ No pude conectar al bridge A2A en {args.url}")
        print("   ¿Está corriendo chita_a2a_server.py y el chatbot Prolog?")
        sys.exit(1)
    except Exception as e:
        print(f"\n❌ Error: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()
