import json
from kafka import KafkaConsumer, KafkaProducer

# Configuración Kafka

#KAFKA_SERVER = 'localhost:9092'
 
KAFKA_SERVER = '66.70.179.213:9092'

# Consumidor para 'tramites'
consumer = KafkaConsumer(
    'tramites',
    bootstrap_servers=[KAFKA_SERVER],
    auto_offset_reset='earliest',
    group_id='sistema_motor',
    value_deserializer=lambda m: json.loads(m.decode('utf-8'))
)

# Productor para 'tramitesResultados'
producer = KafkaProducer(
    bootstrap_servers=[KAFKA_SERVER],
    value_serializer=lambda v: json.dumps(v).encode('utf-8')
)

print("⚙️  Sistema auxiliar escuchando en el tópico 'tramites'...")

for mensaje in consumer:
    datos = mensaje.value
    print("📩 Trámite recibido:", json.dumps(datos, indent=2, ensure_ascii=False))

    # Extraer información
    usuario = datos.get("UsuarioChatBot", "desconocido")
#    tramite = datos.get("Tramite", "desconocido")
    codigo = datos.get("CodigoInterno", "sin_codigo")
    variables = datos.get("Variables", [])

    # Simular procesamiento (se puede reemplazar por lógica real)
    nombres = []
    for var in variables:
        if var.get("Codigo") in ["nombre", "apellido"]:
            nombres.append(var.get("Valor", ""))
    nombre_completo = " ".join(nombres).strip()

    # Crear resultado simulado
    resultado = {
        "UsuarioChatBot": usuario,
        "CodigoInterno": codigo,
        "Excepcion": "",
        "Respuestas": [{
        "Mensaje": f"✅ Trámite  completado exitosamente para {nombre_completo}.",
        "Contenido": f"https://tramites.gob.ar/documentos/{codigo}.pdf"
        }]
    }

    # Enviar resultado al tópico de salida
    producer.send('tramitesResultados', resultado)
    print("📤 Resultado enviado:", json.dumps(resultado, indent=2, ensure_ascii=False))
