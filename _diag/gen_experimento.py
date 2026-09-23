import base64, json, urllib.request, urllib.parse, re, os
import numpy as np, cv2
from dotenv import load_dotenv

load_dotenv()
SOVRA = 'https://thinknetc3.ddns.net/chitaV2/APISovraV2/api/Sovra/PedirVerificacion'
TOKEN = os.getenv('SOVRA_TOKEN')
WEBHOOK = os.getenv('FLASKURL').rstrip('/') + '/identificacion_usuario'
CLAIMS = ["Apellido", "Nombres", "CUIT", "FechaNacimiento", "Entidad"]
DET = cv2.QRCodeDetector()

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
    print(f"  {nombre}: self-test {'OK' if data == texto else 'NO'}")

def crear_sesion(urlrespuesta):
    cred_id = 'ch' + base64.b16encode(os.urandom(6)).decode().lower()
    dcql = {"dcql_query": {"credentials": [{"id": cred_id, "format": "vc+sd-jwt",
        "claims": [{"path": [c]} for c in CLAIMS]}]}}
    url = f'{SOVRA}?URLRespuesta={urlrespuesta}&ModoQR=1&Dimension=655'
    req = urllib.request.Request(url, data=json.dumps(dcql).encode(), method='POST',
        headers={'Authorization': f'Bearer {TOKEN}', 'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=30) as r:
        d = json.loads(r.read().decode())
    v = d['verificacion']
    print(f"  {cred_id}: session {v['session_id'][:8]}... respuestaOK={d.get('respuestaOK', d.get('RespuestaOK'))} msgErr={d.get('msgErr', d.get('MsgErr',''))[:60]}")
    return v['authorization_request_uri_ref']

print("E1: URLRespuesta CRUDA (sin url-encode)")
E1 = crear_sesion(WEBHOOK)
print("E2: URLRespuesta URL-ENCODED (como la manda el chatbot)")
E2 = crear_sesion(urllib.parse.quote(WEBHOOK, safe=''))

qr_png(E1, 'qr_E1')
qr_png(E2, 'qr_E2')
html = f"""<html><head><meta charset='utf-8'><title>Experimento relay</title></head><body>
<p><b>EXPIRA EN ~10 MINUTOS.</b> Escanear con la app de Sovra:</p>
<h3>E1 - URLRespuesta cruda: {WEBHOOK}</h3><img src='/static/qr_E1.png' width='340'>
<h3>E2 - URLRespuesta url-encoded (control)</h3><img src='/static/qr_E2.png' width='340'>
<p>Despues de cada escaneo y verificacion, se revisa si llego el callback a flask.</p>
</body></html>"""
open('static/diag3.html', 'w').write(html)
print("listo: static/diag3.html")
