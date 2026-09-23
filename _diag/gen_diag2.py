import base64, json, urllib.request, urllib.parse, re, os
import numpy as np, cv2
from dotenv import load_dotenv

load_dotenv()
SOVRA = 'https://thinknetc3.ddns.net/chitaV2/APISovraV2/api/Sovra/PedirVerificacion'
TOKEN = os.getenv('SOVRA_TOKEN', 'kjedWBHKJHWEBJXNDLWKED87OWLAKJSBDA')
WEBHOOK = os.getenv('FLASKURL').rstrip('/') + '/identificacion_usuario'
CLAIMS = ["Apellido", "Nombres", "CUIT", "FechaNacimiento", "Entidad"]
DET = cv2.QRCodeDetector()

def crear_sesion():
    cred_id = 'ch' + base64.b16encode(os.urandom(6)).decode().lower()
    dcql = {"dcql_query": {"credentials": [{"id": cred_id, "format": "vc+sd-jwt",
        "claims": [{"path": [c]} for c in CLAIMS]}]}}
    url = f'{SOVRA}?URLRespuesta={urllib.parse.quote(WEBHOOK, safe="")}&ModoQR=1&Dimension=655'
    req = urllib.request.Request(url, data=json.dumps(dcql).encode(), method='POST',
        headers={'Authorization': f'Bearer {TOKEN}', 'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=30) as r:
        d = json.loads(r.read().decode())
    v = d['verificacion']
    m = re.search(r'request_uri=(https?%3A%2F%2F[^&]+)', v['authorization_request_uri_ref'])
    ru = urllib.parse.unquote(m.group(1))
    req2 = urllib.request.Request(ru, headers={'User-Agent': 'Mozilla/5.0'})
    with urllib.request.urlopen(req2, timeout=30) as r:
        jwt = r.read().decode()
    p = jwt.split('.')[1]; p += '=' * (-len(p) % 4)
    payload = json.loads(base64.urlsafe_b64decode(p))
    return dict(cred_id=cred_id, sid=v['session_id'],
                ref=v['authorization_request_uri_ref'],
                full=v['authorization_request_uri'], payload=payload)

def qr_png(texto, nombre):
    import qrcode
    qr = qrcode.QRCode(error_correction=qrcode.constants.ERROR_CORRECT_L, border=4)
    qr.add_data(texto)
    qr.make(fit=True)
    mat = np.array(qr.get_matrix(), dtype=np.uint8)
    img8 = ((1 - mat) * 255).astype(np.uint8)
    img8 = cv2.resize(img8, (img8.shape[1]*8, img8.shape[0]*8), interpolation=cv2.INTER_NEAREST)
    cv2.imwrite(f'static/{nombre}.png', img8)
    data, _, _ = DET.detectAndDecode(img8)
    print(f"  {nombre}: len {len(texto)}, version QR {qr.version}, self-test: {'OK' if data == texto else 'NO'}")

ses = crear_sesion()
cid = ses['payload']['client_id']
pl = ses['payload']
dcql_enc = urllib.parse.quote(json.dumps(pl['dcql_query'], separators=(',', ':')), safe='')
ru_enc = urllib.parse.quote(pl['response_uri'], safe='')

T = {}
T['T1'] = ('request_uri (formato actual = QR de Sovra)', ses['ref'])
T['T2'] = ('parametros a nivel URL (sin dcql en URL)',
    f"openid4vp://?client_id={cid}&response_type=vp_token&response_mode=direct_post&response_uri={ru_enc}&nonce={pl['nonce']}&state={pl['state']}")
T['T3'] = ('request_uri + scope=openid', ses['ref'] + '&scope=openid')
T['T4'] = ('request JWT inline (JAR)', ses['full'])

html = ["<html><head><meta charset='utf-8'><title>Diagnostico 2</title></head><body>",
        f"<p>session: {ses['sid']} | credentialID: {ses['cred_id']} | <b>EXPIRA EN ~10 MINUTOS</b></p>"]
for k, (titulo, url) in T.items():
    qr_png(url, f'qr_{k}')
    html.append(f"<h3>{k}: {titulo}</h3><p>len {len(url)}</p><img src='/static/qr_{k}.png' width='320'><p><a href='{url}'>{k} - abrir link</a></p>")
html.append("</body></html>")
open('static/diag2.html', 'w').write('\n'.join(html))
print("listo: static/diag2.html con", ', '.join(T))
