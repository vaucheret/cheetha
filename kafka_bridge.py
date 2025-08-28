from flask import Flask, request, jsonify
from kafka import KafkaProducer, KafkaConsumer
import threading
import json

app = Flask(__name__)
KAFKA_SERVER = 'localhost:9092'
#KAFKA_SERVER = '66.70.179.213:9092'


# Enviar a Kafka
producer = KafkaProducer(
    bootstrap_servers=KAFKA_SERVER,
    value_serializer=lambda v: json.dumps(v).encode('utf-8')
)

# Almacena las respuestas por CódigoInterno
resultados_tramite = {}

@app.route('/enviar_a_kafka', methods=['POST'])
def enviar_a_kafka():
    data = request.json
    topic = data.get("topic", "tramites")
    mensaje = data.get("mensaje", {})
    print(f"[→] Trámite enviado a Kafka ({topic}): {mensaje}")
    producer.send(topic, mensaje)
    return jsonify({"status": "ok"})

@app.route('/resultado_tramite', methods=['GET'])
def resultado_tramite():
    usuario = request.args.get('usuario')
    codigo = request.args.get('codigo')
    clave = (usuario, codigo)
    if clave in resultados_tramite:
        return jsonify({"status": "ok", "resultado": resultados_tramite[clave]})
    else:
        return jsonify({"status": "pending"}), 404

def escuchar_resultados():
    consumer = KafkaConsumer(
        'tramitesResultados',
        bootstrap_servers=KAFKA_SERVER,
        value_deserializer=lambda m: json.loads(m.decode('utf-8')),
        auto_offset_reset='latest',
        group_id='resultados-consumer',
        enable_auto_commit=True
    )

    print("🎧 Escuchando tópico 'tramitesResultados'...")
    for message in consumer:
        data = message.value
        usuario = data.get("Usuario")
        codigo = data.get("CodigoInterno")
        if usuario and codigo:
            resultados_tramite[(usuario, codigo)] = data
            print(f"[✔] Resultado recibido para {usuario}/{codigo} → {data}")

if __name__ == "__main__":
    threading.Thread(target=escuchar_resultados, daemon=True).start()
    app.run(port=8090)
