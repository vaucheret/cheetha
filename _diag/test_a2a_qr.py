import json, urllib.request, base64, re, sys
import numpy as np, cv2

BRIDGE = "http://localhost:8001/a2a"
DETS = cv2.QRCodeDetector()

def send(text, task_id=None, context_id=None):
    msg = {"role": "user", "parts": [{"kind": "text", "text": text}], "messageId": "t-" + text[:8] + task_id_suffix()}
    if task_id: msg["taskId"] = task_id
    if context_id: msg["contextId"] = context_id
    payload = {"jsonrpc": "2.0", "id": "1", "method": "message/send", "params": {"message": msg}}
    req = urllib.request.Request(BRIDGE, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=70) as r:
        resp = json.loads(r.read().decode())
    if "error" in resp:
        print("  RPC ERROR:", resp["error"]); sys.exit(1)
    return resp["result"]

import itertools
_n = itertools.count()
def task_id_suffix():
    return str(next(_n))

task_id, context_id = None, None
turnos = ["hola", "Las Parejas", "renovación de licencia de conducir", "si", "si", "si", "si"]
for turno in turnos:
    print(f"USER: {turno}")
    task = send(turno, task_id, context_id)
    task_id, context_id = task["id"], task["contextId"]
    text = task["status"]["message"]["parts"][0]["text"] if task["status"].get("message") else "(sin mensaje)"
    estado = task["status"]["state"]
    print(f"CHITA ({estado}): {text[:180]}")
    arts = task.get("artifacts", [])
    for a in arts:
        for p in a.get("parts", []):
            f = p.get("file") or {}
            if f.get("mimeType") == "image/png" and f.get("uri", "").startswith("data:image/png;base64,"):
                raw = base64.b64decode(f["uri"].split(",", 1)[1])
                open("_diag/qr_a2a.png", "wb").write(raw)
                img = cv2.imread("_diag/qr_a2a.png", cv2.IMREAD_GRAYSCALE)
                d, _, _ = DETS.detectAndDecode(img)
                print(f"  ARTIFACT QR: {len(raw)} bytes | decodifica: {d[:90]}")
                print(f"  ES openid4vp ref: {'openid4vp://?client_id' in d and 'request_uri=' in d}")
    if estado == "auth-required":
        print("\n*** ESTADO auth-required ALCANZADO ***")
        sys.exit(0)
print("\n(no se llegó a auth-required en estos turnos)")
