from flask import Flask, request, jsonify
from kafka import KafkaProducer, KafkaConsumer
from dotenv import load_dotenv
import threading
import json
import requests
import os

app = Flask(__name__)

load_dotenv()

#KAFKA_SERVER = "localhost:9092"
KAFKA_SERVER = '66.70.179.213:9092'
PROLOG_BASE_URL = os.getenv("PROLOG_BASE_URL")
TRAM_PROLOG_URL = f"{PROLOG_BASE_URL}/notificacion_tramite"


# Almacena las respuestas SINCRÓNICAS
resultados_tramite = {}

@app.route('/enviar_a_kafka', methods=['POST'])
def enviar_a_kafka():
    data = request.json
    topic = data.get("topic", "tramitesPrueba")
    kafka_server = data.get("url",KAFKA_SERVER),
    mensaje = data.get("mensaje", {})
    producer = KafkaProducer(
    bootstrap_servers=kafka_server,
    value_serializer=lambda v: json.dumps(v).encode('utf-8'))
    print(f"[→] Trámite enviado a Kafka ({topic}): {mensaje}")
    producer.send(topic, mensaje)
    return jsonify({"status": "ok"})

# @app.route('/resultado_tramite', methods=['GET'])
# def resultado_tramite():
#     usuario = request.args.get('usuario')
#     codigo = request.args.get('codigo')
#     idtramite = request.args.get('id')
#     clave = (usuario, codigo, idtramite)

#     if clave in resultados_tramite:
#         resultado = resultados_tramite.pop(clave)
#         return jsonify({"status": "ok", "resultado": resultado})
#     else:
#         return jsonify({"status": "pending"}), 404


# =============================
# Listener SINCRÓNICO
# =============================
# def escuchar_resultados():
#     consumer = KafkaConsumer(
#         'tramitesResultados',
#         bootstrap_servers=KAFKA_SERVER,
#         value_deserializer=lambda m: json.loads(m.decode('utf-8')),
#         auto_offset_reset='latest',
#         group_id='resultados-consumer',
#         enable_auto_commit=True
#     )

#     print("🎧 Escuchando tópico 'tramitesResultados'...")

#     for message in consumer:
#         data = message.value
#         usuario = data.get("UsuarioChatBot")
#         codigo = data.get("CodigoTramite")
#         idtramite = data.get("TramiteID")

#         if usuario and codigo and idtramite:
#             resultados_tramite[(usuario, codigo, idtramite)] = data
#             print(f"[✔] Resultado sincrónico {usuario}/{codigo}/{idtramite}")


# =============================
# Listener ASINCRÓNICO
# =============================
def escuchar_tramites_asincronicos():
    consumer = KafkaConsumer(
        'tramitesAsincronicos',
        bootstrap_servers=KAFKA_SERVER,
        value_deserializer=lambda m: json.loads(m.decode('utf-8')),
        auto_offset_reset='latest',
        group_id='asincronicos-consumer',
        enable_auto_commit=True
    )

    print("🎧 Escuchando tópico 'tramitesAsincronicos'...")

    for message in consumer:
        data = message.value
        usuario = data.get("UsuarioChatBot")
        idtramite = data.get("TramiteID")

        print(f"[⏳] Resultado asincrónico recibido: {data}")

        try:
            response = requests.post(
                TRAM_PROLOG_URL,
                json={
                    "user_id": usuario,
                    "tramite_id": idtramite,
                    "resultado": data
                },
                timeout=5
            )
            print(f"[→] Notificado a Prolog ({response.status_code})")

        except Exception as e:
            print(f"[✖] Error notificando a Prolog: {e}")


if __name__ == "__main__":
    # threading.Thread(target=escuchar_resultados, daemon=True).start()
    threading.Thread(target=escuchar_tramites_asincronicos, daemon=True).start()
    app.run(port=8090)
