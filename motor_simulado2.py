from kafka import KafkaConsumer, KafkaProducer
from dotenv import load_dotenv
import json
import time
import random
import os

load_dotenv()

KAFKA_SERVER = os.getenv("KAFKA_BROKER", "66.70.179.213:9092")
TOPICO_ENVIO = os.getenv("KAFKA_TOPICO_ENVIO", "tramitesPrueba")
TOPICO_RESPUESTA = os.getenv("KAFKA_TOPICO_RESPUESTA", "tramitesAsincronicos")

consumer = KafkaConsumer(
    TOPICO_ENVIO,
    bootstrap_servers=KAFKA_SERVER,
    value_deserializer=lambda m: json.loads(m.decode("utf-8")),
    auto_offset_reset="latest",
    group_id="motor-simulado"
)

producer = KafkaProducer(
    bootstrap_servers=KAFKA_SERVER,
    value_serializer=lambda v: json.dumps(v).encode("utf-8")
)

print(f"🤖 Motor simulado escuchando '{TOPICO_ENVIO}'...")

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

    producer.send(TOPICO_RESPUESTA, resultado)
    print(f"📤 Resultado enviado (asincrónico): {resultado}")
