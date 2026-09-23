import base64, json, urllib.request, urllib.parse, re, os, sys
import numpy as np, cv2
from dotenv import load_dotenv

load_dotenv()
SOVRA = 'https://thinknetc3.ddns.net/chitaV2/APISovraV2/api/Sovra/PedirVerificacion'
TOKEN = os.getenv('SOVRA_TOKEN')
WEBHOOK = os.getenv('FLASKURL').rstrip('/') + '/identificacion_usuario'
CLAIMS = ["Apellido", "Nombres", "CUIT", "FechaNacimiento", "Entidad"]
UA = {'User-Agent': 'Mozilla/5.0'}

def crear_sesion():
    cred_id = 'ch' + base64.b16encode(os.urandom(6)).decode().lower()
    dcql = {"dcql_query": {"credentials": [{"id": cred_id, "format": "vc+sd-jwt",
        "claims": [{"path": [c]} for c in CLAIMS]}]}}
    url = f'{SOVRA}?URLRespuesta={WEBHOOK}&ModoQR=1&Dimension=655'
    req = urllib.request.Request(url, data=json.dumps(dcql).encode(), method='POST',
        headers={'Authorization': f'Bearer {TOKEN}', 'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=30) as r:
        d = json.loads(r.read().decode())
    v = d['verificacion']
    return cred_id, v['session_id'], v['authorization_request_uri_ref']

def jwt_de(sid):
    m = re.search(r'request_uri=(https?%3A%2F%2F[^&]+)', ref)
    ru = urllib.parse.unquote(m.group(1))
    with urllib.request.urlopen(urllib.request.Request(ru, headers=UA), timeout=15) as r:
        jwt = r.read().decode()
    p = jwt.split('.')[1]; p += '=' * (-len(p) % 4)
    return jwt, json.loads(base64.urlsafe_b64decode(p))

cred_id, sid, ref = crear_sesion()
print(f"sesion E3: {sid} | credentialID: {cred_id}")
jwt, payload = jwt_de(sid)
state = payload['state']
dp = f'https://api.sovra.io/wallet/verifier/direct_post/{sid}'

def sondeo(etiqueta):
    data = urllib.parse.urlencode({'vp_token': 'FAKE', 'state': state}).encode()
    try:
        with urllib.request.urlopen(urllib.request.Request(dp, data=data, headers=UA), timeout=15) as r:
            print(f"sondeo {etiqueta}: {r.status} {r.read().decode()[:200]}")
    except urllib.error.HTTPError as e:
        print(f"sondeo {etiqueta}: {e.code} {e.read().decode()[:200]}")
    except Exception as e:
        print(f"sondeo {etiqueta}: error {e}")

sondeo('ANTES del escaneo (linea base)') if False else None

qr = qrcode = __import__('qrcode').QRCode(error_correction=1, border=4)
qr.add_data(ref); qr.make(fit=True)
mat = np.array(qr.get_matrix(), dtype=np.uint8)
img8 = ((1 - mat) * 255).astype(np.uint8)
img8 = cv2.resize(img8, (img8.shape[1]*8, img8.shape[0]*8), interpolation=cv2.INTER_NEAREST)
cv2.imwrite('static/qr_E3.png', img8)
html = f"""<html><head><meta charset='utf-8'><title>E3</title></head><body>
<p>session {sid[:8]}... credentialID {cred_id} - <b>EXPIRA ~10 MIN</b></p>
<img src='/static/qr_E3.png' width='360'></body></html>"""
open('static/diag4.html', 'w').write(html)
json.dump({'sid': sid, 'state': state, 'cred_id': cred_id, 'dp': dp},
          open('_diag/e3.json', 'w'))
print("listo: static/diag4.html - que escanee el usuario")
