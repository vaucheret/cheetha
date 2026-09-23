import re, base64, json, urllib.request
import numpy as np, cv2

# 1) Reconstruir la matriz del QR desde el SVG y decodificarla
svg = open('_diag/qr.svg').read()
rects = re.findall(r'<rect x="(\d+)" y="(\d+)" width="(\d+)" height="(\d+)" fill="(#\w+)"', svg)
M, OFF = 7, 28
N = (539 - 2*OFF) // M
grid = np.zeros((N, N), dtype=np.uint8)
for x, y, w, h, fill in rects:
    x, y, w, h = int(x), int(y), int(w), int(h)
    if fill == '#000000':
        c0, r0 = (x-OFF)//M, (y-OFF)//M
        c1, r1 = (x-OFF+w)//M, (y-OFF+h)//M
        grid[r0:r1, c0:c1] = 1
print(f"grilla: {N}x{N} modulos, {len(rects)} rects")

img = np.full(((N+16)*10, (N+16)*10), 255, dtype=np.uint8)
for r in range(N):
    for c in range(N):
        if grid[r, c]:
            img[(r+8)*10:(r+9)*10, (c+8)*10:(c+9)*10] = 0
cv2.imwrite('_diag/qr_render.png', img)
det = cv2.QRCodeDetector()
data, pts, _ = det.detectAndDecode(img)
print("QR de Sovra decodificado:")
print(data if data else "(no decodifico)")

# 2) Descargar el request object de la sesion y decodificar el JWT
sid = 'cc20ff89-2796-403b-b17b-f3c85bbf72b5'
url = f'https://api.sovra.io/wallet/verifier/request/{sid}'
try:
    req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
    with urllib.request.urlopen(req, timeout=15) as r:
        jwt = r.read().decode()
    print("\nrequest_uri devuelve (primeros 60):", jwt[:60])
    p = jwt.split('.')[1]
    p += '=' * (-len(p) % 4)
    payload = json.loads(base64.urlsafe_b64decode(p))
    print("\npayload del request JWT:")
    print(json.dumps(payload, indent=2)[:1500])
except Exception as e:
    print("ERROR descargando request:", e)

# 3) Para comparar: decodificar QRs regenerados de los links A y B
client_id = 'decentralized_identifier%3Adid%3Asovra%3A0x29053d65e9b9c649eddc9252253713904a8d07b8'
try:
    linkA = f'openid4vp://?client_id={client_id}&request_uri=https%3A%2F%2Fapi.sovra.io%2Fwallet%2Fverifier%2Frequest%2F{sid}'
    linkB = f'openid4vp://?client_id={client_id}&request={jwt}'
    enc = cv2.QRCodeEncoder.create()
    for name, link in [('A', linkA), ('B', linkB)]:
        q = enc.encode(link)
        d2, _, _ = det.detectAndDecode(q)
        print(f"\nQR regenerado de link {name}: decodifica={bool(d2)}, coincide contenido={d2 == link}, len={len(link)}")
        # comparar con el QR de sovra
        if d2 == data:
            print(f"  ==> EL QR DE SOVRA ES EXACTAMENTE EL LINK {name}")
except Exception as e:
    print("comparacion A/B fallo:", e)
