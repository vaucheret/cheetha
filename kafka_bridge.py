from flask import Flask, request, jsonify
from kafka import KafkaProducer, KafkaConsumer
import threading
import json

app = Flask(__name__)
#KAFKA_SERVER = 'localhost:9092'
KAFKA_SERVER = '66.70.179.213:9092'


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
    topic = data.get("topic", "tramites2")
    mensaje = data.get("mensaje", {})
    print(f"[→] Trámite enviado a Kafka ({topic}): {mensaje}")
    producer.send(topic, mensaje)
    return jsonify({"status": "ok"})

@app.route('/resultado_tramite', methods=['GET'])
def resultado_tramite():
    usuario = request.args.get('usuario')
    codigo = request.args.get('codigo')
    idtramite = request.args.get('id')   # cambio agregando codigo de instancia
    clave = (usuario, codigo, idtramite) # cambio agregando codigo de instancia
    if clave in resultados_tramite:
        resultado = resultados_tramite.pop(clave)  
        return jsonify({"status": "ok", "resultado": resultado})
    else:
        return jsonify({"status": "pending"}), 404

def escuchar_resultados():
    consumer = KafkaConsumer(
        'tramitesResultados2',
        bootstrap_servers=KAFKA_SERVER,
        value_deserializer=lambda m: json.loads(m.decode('utf-8')),
        auto_offset_reset='latest',
        group_id='resultados-consumer',
        enable_auto_commit=True
    )

    print("🎧 Escuchando tópico 'tramitesResultados2'...")
    for message in consumer:
        data = message.value
        usuario = data.get("UsuarioChatBot")
        codigo = data.get("CodigoTramite")
        idtramite = data.get("TramiteID") # cambio agregando codigo de instancia
        if usuario and codigo and idtramite: # cambio agregando codigo de instancia
            resultados_tramite[(usuario, codigo, idtramite)] = data # cambio agregando codigo de instancia
            print(f"[✔] Resultado recibido para {usuario}/{codigo}/{idtramite} → {data}") # cambio agregando codigo de instancia

if __name__ == "__main__":
    threading.Thread(target=escuchar_resultados, daemon=True).start()
    app.run(port=8090)
