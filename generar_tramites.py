import json
import random
import os

# Definiciones de trámites con sus descripciones específicas
tramites_definidos = [
    {
        "nombre": "certificado de nacimiento",
        "descripcion": "Documento oficial que acredita el nacimiento de una persona, necesario para trámites de identidad y registro civil",
        "variables_comunes": ["booleano:¿Tenés turno asignado?", "booleano:¿Contás con el acta de nacimiento?", "texto:Nombre completo del recién nacido"]
    },
    {
        "nombre": "licencia de conducir",
        "descripcion": "Permiso oficial para conducir vehículos, requiere examen médico y de manejo",
        "variables_comunes": ["booleano:¿Aprobaste el examen teórico?", "booleano:¿Realizaste el examen médico?", "texto:Tipo de licencia solicitada"]
    },
    {
        "nombre": "certificado de antecedentes penales",
        "descripcion": "Documento que certifica la ausencia de antecedentes penales, requerido para trabajos y trámites oficiales",
        "variables_comunes": ["numero:Ingrese su número de DNI", "texto:Motivo de la solicitud", "booleano:¿Es para uso en el exterior?"]
    },
    {
        "nombre": "permiso de construcción",
        "descripcion": "Autorización municipal para realizar obras de construcción o refacción en propiedades",
        "variables_comunes": ["texto:Dirección de la obra", "texto:Tipo de construcción", "numero:Metros cuadrados a construir"]
    },
    {
        "nombre": "certificado de libre deuda municipal",
        "descripcion": "Documento que certifica que no se adeudan impuestos municipales sobre una propiedad",
        "variables_comunes": ["numero:Número de partida inmobiliaria", "texto:Dirección de la propiedad", "numero:Ingrese su CUIT"]
    },
    {
        "nombre": "inscripción escolar",
        "descripcion": "Registro de estudiantes en instituciones educativas públicas para el ciclo lectivo",
        "variables_comunes": ["texto:Nombre completo del estudiante", "fecha:Fecha de nacimiento", "texto:Escuela de preferencia"]
    },
    {
        "nombre": "permiso de trabajo para menores",
        "descripcion": "Autorización legal para que menores de edad puedan trabajar en condiciones reguladas",
        "variables_comunes": ["numero:Edad del menor", "texto:Tipo de trabajo a realizar", "booleano:¿Cuenta con autorización de los padres?"]
    },
    {
        "nombre": "certificado de discapacidad",
        "descripcion": "Documento oficial que acredita la condición de discapacidad para acceder a beneficios y derechos",
        "variables_comunes": ["texto:Tipo de discapacidad", "booleano:¿Cuenta con informes médicos?", "fecha:Fecha de los estudios médicos"]
    },
    {
        "nombre": "licencia comercial",
        "descripcion": "Permiso municipal para ejercer actividades comerciales en un local determinado",
        "variables_comunes": ["texto:Tipo de actividad comercial", "texto:Dirección del local", "numero:Superficie del local en m2"]
    },
    {
        "nombre": "certificado de residencia",
        "descripcion": "Documento que acredita el domicilio real de una persona en una jurisdicción específica",
        "variables_comunes": ["texto:Dirección actual", "numero:Tiempo de residencia en años", "booleano:¿Cuenta con servicios a su nombre?"]
    },
    {
        "nombre": "permiso de circulación vehicular",
        "descripcion": "Autorización temporal para circular con vehículos en situaciones especiales o sin documentación completa",
        "variables_comunes": ["texto:Patente del vehículo", "texto:Motivo del permiso", "fecha:Fecha hasta la cual necesita el permiso"]
    },
    {
        "nombre": "certificado de defunción",
        "descripcion": "Documento oficial que certifica el fallecimiento de una persona, necesario para trámites sucesorios",
        "variables_comunes": ["texto:Nombre completo del fallecido", "fecha:Fecha de fallecimiento", "texto:Lugar de fallecimiento"]
    },
    {
        "nombre": "inscripción de matrimonio",
        "descripcion": "Registro civil del matrimonio entre dos personas, con validez legal oficial",
        "variables_comunes": ["texto:Nombres de los contrayentes", "fecha:Fecha del matrimonio", "booleano:¿Tienen testigos?"]
    },
    {
        "nombre": "permiso de espectáculo público",
        "descripcion": "Autorización municipal para realizar eventos, shows o espectáculos abiertos al público",
        "variables_comunes": ["texto:Tipo de espectáculo", "fecha:Fecha del evento", "numero:Cantidad estimada de asistentes"]
    },
    {
        "nombre": "certificado de vacunación",
        "descripcion": "Documento que acredita las vacunas recibidas, requerido para viajes e inscripciones escolares",
        "variables_comunes": ["texto:Vacunas requeridas", "booleano:¿Es para viaje internacional?", "fecha:Fecha de la última vacuna"]
    },
    {
        "nombre": "licencia de pesca",
        "descripcion": "Permiso oficial para realizar actividades de pesca deportiva o comercial en aguas jurisdiccionales",
        "variables_comunes": ["texto:Tipo de pesca (deportiva/comercial)", "texto:Zona de pesca", "booleano:¿Cuenta con embarcación propia?"]
    },
    {
        "nombre": "certificado de adopción",
        "descripcion": "Documento legal que formaliza el proceso de adopción de menores de edad",
        "variables_comunes": ["texto:Nombre del menor a adoptar", "booleano:¿Completó el proceso de evaluación?", "texto:Estado civil de los adoptantes"]
    },
    {
        "nombre": "permiso de tenencia de armas",
        "descripcion": "Autorización legal para poseer armas de fuego con fines deportivos, de colección o defensa personal",
        "variables_comunes": ["texto:Tipo de arma", "texto:Motivo de la tenencia", "booleano:¿Aprobó el examen psicofísico?"]
    },
    {
        "nombre": "certificado de estudios",
        "descripcion": "Documento que acredita la finalización de estudios primarios, secundarios o superiores",
        "variables_comunes": ["texto:Nivel educativo completado", "texto:Institución educativa", "numero:Año de finalización"]
    },
    {
        "nombre": "inscripción de vehículo",
        "descripcion": "Registro oficial de un vehículo nuevo o usado en el registro automotor correspondiente",
        "variables_comunes": ["texto:Marca y modelo del vehículo", "numero:Año del vehículo", "booleano:¿Es vehículo 0km?"]
    }
]

# Preguntas adicionales por tipo
preguntas_adicionales = {
    "booleano": [
        "¿Realizaste el pago de las tasas?",
        "¿Tenés toda la documentación completa?",
        "¿Es urgente este trámite?",
        "¿Necesitás certificación apostillada?",
        "¿Tenés representante legal?"
    ],
    "texto": [
        "Observaciones adicionales",
        "Número de teléfono de contacto",
        "Email de contacto",
        "Profesión u ocupación",
        "Nacionalidad"
    ],
    "numero": [
        "Código postal de residencia",
        "Número de expediente anterior",
        "Cantidad de copias solicitadas",
        "Número de CUIL/CUIT",
        "Número de legajo"
    ],
    "fecha": [
        "Fecha de nacimiento",
        "Fecha de vencimiento del documento anterior",
        "Fecha límite para completar el trámite",
        "Fecha de inicio de actividades",
        "Fecha del último trámite similar"
    ]
}

def generar_variables_tramite(variables_base, cantidad_adicional=2):
    variables = []
    codigo_counter = 10
    
    # Agregar variables específicas del trámite
    for var_def in variables_base:
        tipo, pregunta = var_def.split(":", 1)
        variables.append({
            "Codigo": str(codigo_counter),
            "Tipo": tipo,
            "Vector": "No",
            "PorDefecto": "",
            "Valor": "",
            "Pedir": "Si",
            "Caption": pregunta
        })
        codigo_counter += 1
    
    # Agregar variables adicionales aleatorias
    for _ in range(cantidad_adicional):
        tipo = random.choice(list(preguntas_adicionales.keys()))
        pregunta = random.choice(preguntas_adicionales[tipo])
        
        variable = {
            "Codigo": str(codigo_counter),
            "Tipo": tipo,
            "Vector": "No",
            "PorDefecto": "",
            "Valor": "",
            "Pedir": "Si",
            "Caption": pregunta
        }
        
        # Agregar opciones para algunos campos de texto
        if tipo == "texto" and random.random() < 0.2:
            variable["Vector"] = "Si"
            variable["Valor"] = "-1"
            variable["Opciones"] = [
                f"Opción {j+1}" for j in range(random.randint(2, 4))
            ]
        
        variables.append(variable)
        codigo_counter += 1
    
    return variables

def generar_tramites_multiples():
    tramites_generados = []
    
    # Generar múltiples variantes de cada trámite definido
    for tramite_base in tramites_definidos:
        for variante in range(3):  # 3 variantes por trámite
            codigo_interno = random.randint(100000, 999999)
            
            # Crear variaciones en el nombre
            if variante == 1:
                nombre = f"duplicado de {tramite_base['nombre']}"
                descripcion = f"Duplicado del {tramite_base['descripcion'].lower()}"
            elif variante == 2:
                nombre = f"renovación de {tramite_base['nombre']}"
                descripcion = f"Renovación del {tramite_base['descripcion'].lower()}"
            else:
                nombre = tramite_base['nombre']
                descripcion = tramite_base['descripcion']
            
            variables = generar_variables_tramite(
                tramite_base['variables_comunes'], 
                random.randint(1, 3)
            )
            
            tramite = {
                "Tramite": nombre,
                "CodigoInterno": codigo_interno,
                "Identificacion": descripcion,
                "asincronico": random.choice([True, False]),
                "loginNecesario": random.choice([0, 1]),
                "Variables": variables
            }
            
            tramites_generados.append((tramite, nombre))
    
    return tramites_generados

def guardar_tramites(tramites_generados):
    if not os.path.exists("tramites"):
        os.makedirs("tramites")
    
    for i, (tramite, nombre) in enumerate(tramites_generados):
        nombre_archivo = nombre.replace(" ", "_").replace("de_", "")
        filename = f"tramites/tramite_{nombre_archivo}_{i+1:03d}.json"
        
        with open(filename, 'w', encoding='utf-8') as f:
            json.dump(tramite, f, indent=4, ensure_ascii=False)
        
        print(f"Generado: {filename}")
        print(f"  Trámite: {tramite['Tramite']}")
        print(f"  Descripción: {tramite['Identificacion'][:80]}...")
        print()

if __name__ == "__main__":
    print("Generando trámites con descripciones detalladas...")
    tramites = generar_tramites_multiples()
    guardar_tramites(tramites)
    print(f"¡{len(tramites)} trámites generados exitosamente!")
