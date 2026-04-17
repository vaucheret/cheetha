:- module(generar_tramites, [generar_tramites_multiples/1]).

:- use_module(library(http/json)).
:- use_module(library(random)).
:- use_module(library(apply), [maplist/3]).
:- use_module(library(lists), [append/3]).
:- use_module(library(pcre)).
:- use_module(library(filesex)).

% Definiciones de trámites base con descripciones específicas
tramite_base(
    "certificado de nacimiento",
    "Documento oficial que acredita el nacimiento de una persona, necesario para trámites de identidad y registro civil",
    ["booleano:¿Tenés turno asignado?", "booleano:¿Contás con el acta de nacimiento?", "texto:Nombre completo del recién nacido"],
    "Pasos para realizar el trámite:\n1. Solicitar turno online en www.argentina.gob.ar o acercarse al Registro Civil\n2. Presentar DNI de los padres y acta de nacimiento del hospital\n3. Completar formulario de solicitud en el lugar\n4. Abonar la tasa correspondiente (consultar monto actualizado)\n5. Retirar el certificado en 48-72 horas hábiles"
).

tramite_base(
    "licencia de conducir", 
    "Permiso oficial para conducir vehículos, requiere examen médico y de manejo",
    ["booleano:¿Aprobaste el examen teórico?", "booleano:¿Realizaste el examen médico?", "texto:Tipo de licencia solicitada"],
    "Pasos para realizar el trámite:\n1. Rendir examen teórico en centro de emisión de licencias\n2. Realizar examen médico y psicofísico en centro habilitado\n3. Presentar DNI, certificado médico y comprobante de domicilio\n4. Abonar las tasas correspondientes\n5. Rendir examen práctico de manejo\n6. Retirar la licencia una vez aprobados todos los exámenes"
).

tramite_base(
    "certificado de antecedentes penales",
    "Documento que certifica la ausencia de antecedentes penales, requerido para trabajos y trámites oficiales", 
    ["numero:Ingrese su número de DNI", "texto:Motivo de la solicitud", "booleano:¿Es para uso en el exterior?"],
    "Pasos para realizar el trámite:\n1. Solicitar turno online en www.argentina.gob.ar o llamando al 0800-222-1234\n2. Dirigirse a la oficina del Registro Nacional de Reincidencia con DNI original\n3. Completar formulario de solicitud en el lugar\n4. Abonar la tasa correspondiente (consultar monto actualizado)\n5. Retirar el certificado en 48-72 horas hábiles o solicitar envío por correo"
).

tramite_base(
    "permiso de construcción",
    "Autorización municipal para realizar obras de construcción o refacción en propiedades",
    ["texto:Dirección de la obra", "texto:Tipo de construcción", "numero:Metros cuadrados a construir"],
    "Pasos para realizar el trámite:\n1. Presentar planos firmados por profesional habilitado en la municipalidad\n2. Adjuntar título de propiedad y certificado de libre deuda\n3. Completar formulario de solicitud de permiso de obra\n4. Abonar tasas municipales correspondientes\n5. Esperar inspección municipal del terreno\n6. Retirar el permiso una vez aprobado el proyecto"
).

tramite_base(
    "certificado de libre deuda municipal",
    "Documento que certifica que no se adeudan impuestos municipales sobre una propiedad",
    ["numero:Número de partida inmobiliaria", "texto:Dirección de la propiedad", "numero:Ingrese su CUIT"],
    "Pasos para realizar el trámite:\n1. Dirigirse a la oficina de rentas municipales con DNI\n2. Presentar título de propiedad o boleto de compraventa\n3. Proporcionar número de partida inmobiliaria\n4. Verificar que no existan deudas pendientes\n5. Abonar tasa administrativa si corresponde\n6. Retirar el certificado en el momento o en 24-48 horas"
).

tramite_base(
    "inscripción escolar",
    "Registro de estudiantes en instituciones educativas públicas para el ciclo lectivo",
    ["texto:Nombre completo del estudiante", "fecha:Fecha de nacimiento", "texto:Escuela de preferencia"],
    "Pasos para realizar el trámite:\n1. Dirigirse a la escuela elegida durante el período de inscripción\n2. Presentar DNI del estudiante y de los padres/tutores\n3. Adjuntar certificado de nacimiento y libreta sanitaria\n4. Completar formulario de inscripción con datos del estudiante\n5. Presentar certificado de estudios previos (si corresponde)\n6. Confirmar la vacante y fecha de inicio de clases"
).

tramite_base(
    "permiso de trabajo para menores",
    "Autorización legal para que menores de edad puedan trabajar en condiciones reguladas",
    ["numero:Edad del menor", "texto:Tipo de trabajo a realizar", "booleano:¿Cuenta con autorización de los padres?"],
    "Pasos para realizar el trámite:\n1. Solicitar turno en la oficina de trabajo de menores\n2. Presentar DNI del menor y de los padres/tutores\n3. Adjuntar autorización firmada por ambos padres\n4. Presentar certificado médico que acredite aptitud para el trabajo\n5. Completar formulario con detalles del empleo propuesto\n6. Esperar evaluación y aprobación del permiso"
).

tramite_base(
    "certificado de discapacidad", 
    "Documento oficial que acredita la condición de discapacidad para acceder a beneficios y derechos",
    ["texto:Tipo de discapacidad", "booleano:¿Cuenta con informes médicos?", "fecha:Fecha de los estudios médicos"],
    "Pasos para realizar el trámite:\n1. Solicitar turno en junta médica evaluadora\n2. Presentar DNI y obra social (si tiene)\n3. Adjuntar informes médicos actualizados y estudios complementarios\n4. Completar formulario de solicitud del certificado\n5. Asistir a evaluación médica en fecha asignada\n6. Retirar el certificado una vez emitido el dictamen"
).

tramite_base(
    "licencia comercial",
    "Permiso municipal para ejercer actividades comerciales en un local determinado",
    ["texto:Tipo de actividad comercial", "texto:Dirección del local", "numero:Superficie del local en m2"],
    "Pasos para realizar el trámite:\n1. Presentar solicitud en oficina de habilitaciones comerciales\n2. Adjuntar contrato de alquiler o título de propiedad del local\n3. Presentar plano del local firmado por profesional habilitado\n4. Completar formulario con descripción de la actividad comercial\n5. Abonar tasas municipales correspondientes\n6. Esperar inspección municipal y retirar la habilitación"
).

tramite_base(
    "certificado de residencia",
    "Documento que acredita el domicilio real de una persona en una jurisdicción específica", 
    ["texto:Dirección actual", "numero:Tiempo de residencia en años", "booleano:¿Cuenta con servicios a su nombre?"],
    "Pasos para realizar el trámite:\n1. Dirigirse a la comisaría de la zona con DNI\n2. Presentar facturas de servicios a su nombre (luz, gas, agua)\n3. Adjuntar contrato de alquiler o escritura de propiedad\n4. Completar formulario de solicitud de certificado\n5. Proporcionar datos de dos testigos vecinos\n6. Retirar el certificado en 24-48 horas hábiles"
).

tramite_base(
    "permiso de circulación vehicular",
    "Autorización temporal para circular con vehículos en situaciones especiales o sin documentación completa",
    ["texto:Patente del vehículo", "texto:Motivo del permiso", "fecha:Fecha hasta la cual necesita el permiso"],
    "Pasos para realizar el trámite:\n1. Dirigirse al registro automotor con DNI del titular\n2. Presentar cédula verde o azul del vehículo\n3. Adjuntar comprobante de seguro vigente\n4. Completar formulario explicando el motivo del permiso\n5. Abonar tasa administrativa correspondiente\n6. Retirar el permiso temporal en el momento"
).

tramite_base(
    "certificado de defunción",
    "Documento oficial que certifica el fallecimiento de una persona, necesario para trámites sucesorios",
    ["texto:Nombre completo del fallecido", "fecha:Fecha de fallecimiento", "texto:Lugar de fallecimiento"],
    "Pasos para realizar el trámite:\n1. Dirigirse al Registro Civil con DNI del solicitante\n2. Presentar DNI del fallecido y certificado médico de defunción\n3. Adjuntar acta de defunción del hospital o institución\n4. Completar formulario de solicitud del certificado\n5. Abonar tasa administrativa si corresponde\n6. Retirar el certificado en el momento o en 24 horas"
).

tramite_base(
    "inscripción de matrimonio",
    "Registro civil del matrimonio entre dos personas, con validez legal oficial",
    ["texto:Nombres de los contrayentes", "fecha:Fecha del matrimonio", "booleano:¿Tienen testigos?"],
    "Pasos para realizar el trámite:\n1. Solicitar turno en el Registro Civil con 30 días de anticipación\n2. Presentar DNI de ambos contrayentes y certificados de nacimiento\n3. Adjuntar certificado de soltería de ambos contrayentes\n4. Completar formulario de solicitud de matrimonio\n5. Presentar dos testigos mayores de edad con DNI\n6. Realizar la ceremonia en fecha y hora asignada"
).

tramite_base(
    "permiso de espectáculo público",
    "Autorización municipal para realizar eventos, shows o espectáculos abiertos al público",
    ["texto:Tipo de espectáculo", "fecha:Fecha del evento", "numero:Cantidad estimada de asistentes"],
    "Pasos para realizar el trámite:\n1. Presentar solicitud en oficina de espectáculos públicos con 15 días de anticipación\n2. Adjuntar programa del evento y datos del organizador\n3. Presentar plano del lugar y medidas de seguridad\n4. Contratar servicio de ambulancia y seguridad privada\n5. Abonar tasas municipales correspondientes\n6. Esperar inspección municipal y retirar el permiso"
).

tramite_base(
    "certificado de vacunación",
    "Documento que acredita las vacunas recibidas, requerido para viajes e inscripciones escolares",
    ["texto:Vacunas requeridas", "booleano:¿Es para viaje internacional?", "fecha:Fecha de la última vacuna"],
    "Pasos para realizar el trámite:\n1. Dirigirse al centro de salud con DNI y carnet de vacunación\n2. Verificar que las vacunas estén al día según calendario oficial\n3. Aplicar vacunas faltantes si es necesario\n4. Solicitar certificado internacional si es para viaje\n5. Completar formulario con destino y fechas de viaje\n6. Retirar el certificado en 24-48 horas"
).

tramite_base(
    "licencia de pesca",
    "Permiso oficial para realizar actividades de pesca deportiva o comercial en aguas jurisdiccionales",
    ["texto:Tipo de pesca (deportiva/comercial)", "texto:Zona de pesca", "booleano:¿Cuenta con embarcación propia?"],
    "Pasos para realizar el trámite:\n1. Dirigirse a la oficina de pesca con DNI\n2. Completar formulario especificando tipo y zona de pesca\n3. Presentar certificado médico de aptitud física\n4. Adjuntar documentación de la embarcación (si corresponde)\n5. Abonar tasa anual de licencia de pesca\n6. Retirar la licencia y respetar vedas y límites establecidos"
).

tramite_base(
    "certificado de adopción",
    "Documento legal que formaliza el proceso de adopción de menores de edad",
    ["texto:Nombre del menor a adoptar", "booleano:¿Completó el proceso de evaluación?", "texto:Estado civil de los adoptantes"],
    "Pasos para realizar el trámite:\n1. Inscribirse en el registro de adoptantes\n2. Completar evaluación psicológica y social\n3. Participar en cursos de preparación para adoptantes\n4. Esperar asignación de menor compatible\n5. Realizar período de vinculación supervisada\n6. Formalizar adopción ante juez de familia"
).

tramite_base(
    "permiso de tenencia de armas",
    "Autorización legal para poseer armas de fuego con fines deportivos, de colección o defensa personal",
    ["texto:Tipo de arma", "texto:Motivo de la tenencia", "booleano:¿Aprobó el examen psicofísico?"],
    "Pasos para realizar el trámite:\n1. Solicitar turno en RENAR (Registro Nacional de Armas)\n2. Presentar DNI, certificado de antecedentes penales y contravencionales\n3. Realizar examen psicofísico en centro habilitado\n4. Completar curso de manejo seguro de armas\n5. Justificar motivo de tenencia (deporte, colección, defensa)\n6. Abonar tasas y esperar resolución del permiso"
).

tramite_base(
    "certificado de estudios",
    "Documento que acredita la finalización de estudios primarios, secundarios o superiores",
    ["texto:Nivel educativo completado", "texto:Institución educativa", "numero:Año de finalización"],
    "Pasos para realizar el trámite:\n1. Dirigirse a la institución educativa donde cursó con DNI\n2. Completar formulario de solicitud de certificado\n3. Presentar libreta de calificaciones o analítico\n4. Abonar tasa administrativa si corresponde\n5. Esperar verificación de datos académicos\n6. Retirar el certificado en 5-10 días hábiles"
).

tramite_base(
    "inscripción de vehículo",
    "Registro oficial de un vehículo nuevo o usado en el registro automotor correspondiente",
    ["texto:Marca y modelo del vehículo", "numero:Año del vehículo", "booleano:¿Es vehículo 0km?"],
    "Pasos para realizar el trámite:\n1. Dirigirse al registro automotor con DNI del comprador\n2. Presentar factura de compra y formulario 08 completo\n3. Adjuntar cédula de identificación del automotor\n4. Realizar verificación física del vehículo\n5. Abonar patente, sellos y tasas de inscripción\n6. Retirar título y cédula verde en 10-15 días hábiles"
).

% Preguntas adicionales por tipo
pregunta_adicional(booleano, "¿Realizaste el pago de las tasas?").
pregunta_adicional(booleano, "¿Tenés toda la documentación completa?").
pregunta_adicional(booleano, "¿Es urgente este trámite?").
pregunta_adicional(booleano, "¿Necesitás certificación apostillada?").
pregunta_adicional(booleano, "¿Tenés representante legal?").

pregunta_adicional(texto, "Observaciones adicionales").
pregunta_adicional(texto, "Número de teléfono de contacto").
pregunta_adicional(texto, "Email de contacto").
pregunta_adicional(texto, "Profesión u ocupación").
pregunta_adicional(texto, "Nacionalidad").

pregunta_adicional(numero, "Código postal de residencia").
pregunta_adicional(numero, "Número de expediente anterior").
pregunta_adicional(numero, "Cantidad de copias solicitadas").
pregunta_adicional(numero, "Número de CUIL/CUIT").
pregunta_adicional(numero, "Número de legajo").

pregunta_adicional(fecha, "Fecha de nacimiento").
pregunta_adicional(fecha, "Fecha de vencimiento del documento anterior").
pregunta_adicional(fecha, "Fecha límite para completar el trámite").
pregunta_adicional(fecha, "Fecha de inicio de actividades").
pregunta_adicional(fecha, "Fecha del último trámite similar").

% Generar variables para un trámite
generar_variables_tramite(VariablesBase, CantidadAdicional, Variables) :-
    CodigoInicial = 30,
    procesar_variables_base(VariablesBase, CodigoInicial, VariablesEspecificas, SiguienteCodigo),
    generar_variables_adicionales(CantidadAdicional, SiguienteCodigo, VariablesAdicionales),
    append(VariablesEspecificas, VariablesAdicionales, Variables).

% Procesar variables específicas del trámite
procesar_variables_base([], Codigo, [], Codigo).
procesar_variables_base([VarDef|Resto], Codigo, [Variable|Variables], CodigoFinal) :-
    split_string(VarDef, ":", "", [TipoStr, PreguntaStr]),
    atom_string(Codigo, CodigoStr),
    Variable = _{
        'Codigo': CodigoStr,
        'Tipo': TipoStr,
        'Vector': "No",
        'PorDefecto': "",
        'Valor': "",
        'Pedir': "Si",
        'Caption': PreguntaStr
    },
    SiguienteCodigo is Codigo + 1,
    procesar_variables_base(Resto, SiguienteCodigo, Variables, CodigoFinal).

% Generar variables adicionales aleatorias
generar_variables_adicionales(0, _, []) :- !.
generar_variables_adicionales(Cantidad, Codigo, [Variable|Variables]) :-
    Cantidad > 0,
    findall(Tipo, pregunta_adicional(Tipo, _), Tipos),
    random_member(Tipo, Tipos),
    findall(Pregunta, pregunta_adicional(Tipo, Pregunta), Preguntas),
    random_member(PreguntaSeleccionada, Preguntas),
    atom_string(Tipo, TipoStr),
    atom_string(Codigo, CodigoStr),
    
    % Crear variable básica
    Variable = _{
        'Codigo': CodigoStr,
        'Tipo': TipoStr,
        'Vector': "No",
        'PorDefecto': "",
        'Valor': "",
        'Pedir': "Si",
        'Caption': PreguntaSeleccionada
    },
    
    SiguienteCodigo is Codigo + 1,
    CantidadRest is Cantidad - 1,
    generar_variables_adicionales(CantidadRest, SiguienteCodigo, Variables).

% Generar un trámite completo
generar_tramite_variante(Nombre, Descripcion, VariablesBase, DescripcionPasos, Variante, TramiteDict) :-
    random_between(100000, 999999, CodigoInterno),
    
    % Crear variaciones según el tipo
    (   Variante = 1 ->
        format(string(NombreVariante), "duplicado de ~s", [Nombre]),
        format(string(DescripcionVariante), "Duplicado del ~s", [Descripcion])
    ;   Variante = 2 ->
        format(string(NombreVariante), "renovación de ~s", [Nombre]),
        format(string(DescripcionVariante), "Renovación del ~s", [Descripcion])
    ;   (NombreVariante = Nombre,
        DescripcionVariante = Descripcion)
    ),
    
    % Generar variables
    random_between(1, 3, CantidadAdicional),
    generar_variables_tramite(VariablesBase, CantidadAdicional, Variables),
    
    % Elegir propiedades aleatorias
    random_member(Asincronico, [true, false]),
    random_member(LoginNecesario, [0, 1]),
    
    % Crear el diccionario del trámite
    TramiteDict = _{
        'Tramite': NombreVariante,
        'CodigoInterno': CodigoInterno,
        'Identificacion': DescripcionVariante,
        'descripcion': DescripcionPasos,
        'asincronico': Asincronico,
        'loginNecesario': LoginNecesario,
        'Variables': Variables
    }.

% Generar múltiples trámites
generar_tramites_multiples(_Cantidad) :-
    format("Generando trámites con descripciones detalladas...~n"),
    
    % Crear directorio si no existe
    (   exists_directory("tramites") -> true
    ;   make_directory_path("tramites")
    ),
    
    % Generar trámites
    findall(
        tramite(Nombre, Descripcion, Variables, DescripcionPasos),
        tramite_base(Nombre, Descripcion, Variables, DescripcionPasos),
        TramitesBase
    ),
    
    Contador = 1,
    generar_y_guardar_todos(TramitesBase, Contador),
    
    length(TramitesBase, NumBase),
    TotalGenerados is NumBase * 3,
    format("¡~w trámites generados exitosamente!~n", [TotalGenerados]).

% Generar y guardar todos los trámites
generar_y_guardar_todos([], _).
generar_y_guardar_todos([tramite(Nombre, Descripcion, Variables, DescripcionPasos)|Resto], Contador) :-
    % Generar 3 variantes de cada trámite base
    forall(
        between(0, 2, Variante),
        (
            generar_tramite_variante(Nombre, Descripcion, Variables, DescripcionPasos, Variante, TramiteDict),
            ContadorVariante is Contador * 10 + Variante,
            guardar_tramite_json(TramiteDict, ContadorVariante)
        )
    ),
    SiguienteContador is Contador + 1,
    generar_y_guardar_todos(Resto, SiguienteContador).

% Guardar un trámite en archivo JSON
guardar_tramite_json(TramiteDict, Numero) :-
    NombreTramite = TramiteDict.'Tramite',
    % Limpiar nombre para archivo
    re_replace(" ", "_", NombreTramite, NombreLimpio1, [global]),
    re_replace("de_", "", NombreLimpio1, NombreLimpio, [global]),
    
    format(string(NombreArchivo), "tramites/tramite_~s_~|~`0t~d~3+.json", [NombreLimpio, Numero]),
    
    open(NombreArchivo, write, Stream, [encoding(utf8)]),
    json_write_dict(Stream, TramiteDict, [width(0), indent(4)]),
    close(Stream),
    
    format("Generado: ~s~n", [NombreArchivo]),
    format("  Trámite: ~s~n", [TramiteDict.'Tramite']),
    DescripcionCorta = TramiteDict.'Identificacion',
    (   string_length(DescripcionCorta, Len), Len > 80 ->
        sub_string(DescripcionCorta, 0, 80, _, DescripcionMostrar),
        format("  Descripción: ~s...~n~n", [DescripcionMostrar])
    ;   format("  Descripción: ~s~n~n", [DescripcionCorta])
    ).

% Predicado principal para ejecutar
main :-
    generar_tramites_multiples(60).

% Para ejecutar desde la línea de comandos
:- initialization(main, main).
