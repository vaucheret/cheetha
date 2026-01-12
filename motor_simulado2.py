from kafka import KafkaConsumer, KafkaProducer
import json
import time
import random

KAFKA_SERVER = "localhost:9092"

consumer = KafkaConsumer(
    "tramites",
    bootstrap_servers=KAFKA_SERVER,
    value_deserializer=lambda m: json.loads(m.decode("utf-8")),
    auto_offset_reset="latest",
    group_id="motor-simulado"
)

producer = KafkaProducer(
    bootstrap_servers=KAFKA_SERVER,
    value_serializer=lambda v: json.dumps(v).encode("utf-8")
)

print("🤖 Motor simulado escuchando 'tramites'...")

for msg in consumer:
    data = msg.value
    print(f"📥 Trámite recibido: {data}")

    # simulamos procesamiento
    delay = random.randint(3, 8)
    time.sleep(delay)

    resultado = {
        "UsuarioChatBot": data.get("UsuarioChatBot"),
        "CodigoTramite": data.get("CodigoTramite"),
        "TramiteID": data.get("TramiteID"),
        "Estado": "COMPLETADO",
        "Mensaje": f"Trámite procesado en {delay}s (simulado)",
        "Resultado": {
            "numeroExpediente": random.randint(10000, 99999)
        }
    }

    producer.send("tramitesAsincronicos", resultado)
    print(f"📤 Resultado enviado (asincrónico): {resultado}")
