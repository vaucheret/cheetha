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
    entrada = msg.value
    print(f"📥 Trámite recibido:\n{json.dumps(entrada, indent=2)}")

    time.sleep(random.randint(3, 6))

    respuesta_motor = {
        "URLKafka": KAFKA_SERVER,
        "TopicoKafka": "Pedir_Datos",
        "UsuarioKafka": "--",
        "ClaveKafka": "--",

        # 🔴 claves importantes para Chita
        "CodigoCliente": entrada.get("UsuarioChatBot"),
        "InstanciaTramite": entrada.get("TramiteID"),
        "InstanciaStep": random.randint(400, 500),
        "Accion": 1,
        "Descripción": "Chita necesita que le aporte cierta información",

        "VariablesContexto": [
            {
                "Texto1": "Ingrese su CUIT",
                "Texto2": "33683132859"
            }
        ],

        "VariablesPedidas": [
            {
                "Codigo": 33,
                "Tramite": entrada.get("CodigoTramite"),
                "Orden": 2,
                "Nombre": "Edad",
                "Label": "Ingrese su edad",
                "Clase": 1
            },
            {
                "Codigo": 34,
                "Tramite": entrada.get("CodigoTramite"),
                "Orden": 3,
                "Nombre": "Sexo",
                "Label": "Defina su sexo (M: Masculino - F: Femenino)",
                "Clase": 4
            }
        ],

        "TextoBoton": "",
        "Link": "",
        "Respuestas": [],
        "MensajeEx": ""
    }

    producer.send("tramitesAsincronicos", respuesta_motor)
    print("📤 Respuesta asincrónica enviada al tópico 'tramitesAsincronicos'")
