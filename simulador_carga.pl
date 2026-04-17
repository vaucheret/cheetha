:- module(simulador_carga, [
    iniciar_simulacion/3,
    iniciar_simulacion/4,
    detener_simulacion/0,
    mostrar_estadisticas/0
]).

:- use_module(library(http/http_client)).
:- use_module(library(http/json)).
:- use_module(library(random)).
:- use_module(library(thread)).
:- use_module(library(lists)).
:- use_module(library(time)).

% Configuración
:- dynamic simulacion_activa/0.
:- dynamic estadisticas/6. % usuario, total_consultas, exitosas, fallidas, tiempo_promedio, estado

% URL base del chatbot
chatbot_url('http://localhost:8000/chat').

% Mensajes de prueba simulando usuarios reales
mensajes_prueba([
    "hola",
    "quiero hacer un tramite",
    "necesito renovar mi dni",
    "quiero sacar un pasaporte",
    "si",
    "no",
    "12345678",
    "juan perez",
    "25/12/1990",
    "buenos aires",
    "pausar",
    "continuar",
    "cancelar",
    "gracias",
    "chau"
]).

% Iniciar simulación con parámetros por defecto
iniciar_simulacion(NumUsuarios, DuracionMinutos, PausaEntreConsultas) :-
    iniciar_simulacion(NumUsuarios, DuracionMinutos, PausaEntreConsultas, 'http://localhost:8000/chat').

% Iniciar simulación completa
iniciar_simulacion(NumUsuarios, DuracionMinutos, PausaEntreConsultas, URL) :-
    
    format('🚀 Iniciando simulación de carga:~n'),
    format('   - Usuarios simultáneos: ~w~n', [NumUsuarios]),
    format('   - Duración: ~w minutos~n', [DuracionMinutos]),
    format('   - Pausa entre consultas: ~w segundos~n', [PausaEntreConsultas]),
    format('   - URL del chatbot: ~w~n~n', [URL]),
    
    assertz(simulacion_activa),
    
    % Limpiar estadísticas previas
    retractall(estadisticas(_, _, _, _, _, _)),
    
    % Crear threads para cada usuario simulado
    DuracionSegundos is DuracionMinutos * 60,
    forall(between(1, NumUsuarios, UserNum),
           (format(atom(UserID), 'usuario_test_~w', [UserNum]),
            thread_create(simular_usuario(UserID, DuracionSegundos, PausaEntreConsultas), 
                         ThreadID, [alias(UserID)]),
            format('👤 Usuario ~w iniciado (Thread: ~w)~n', [UserID, ThreadID]))),
    
    format('~n✅ Simulación iniciada. Usa mostrar_estadisticas/0 para ver el progreso.~n'),
    format('   Usa detener_simulacion/0 para parar antes de tiempo.~n').

% Detener simulación
detener_simulacion :-
    (simulacion_activa ->
        retract(simulacion_activa),
        format('🛑 Deteniendo simulación...~n'),
        % Esperar un poco para que los threads terminen
        sleep(2),
        mostrar_estadisticas,
        format('✅ Simulación detenida.~n')
    ;   format('⚠️  No hay simulación activa.~n')).

% Simular un usuario individual
simular_usuario(UserID, DuracionSegundos, PausaEntreConsultas) :-
    get_time(TiempoInicio),
    TiempoFin is TiempoInicio + DuracionSegundos,
    
    % Inicializar estadísticas para este usuario
    assertz(estadisticas(UserID, 0, 0, 0, 0, activo)),
    
    format('🎭 Usuario ~w comenzando simulación~n', [UserID]),
    
    simular_conversacion(UserID, TiempoFin, PausaEntreConsultas),
    
    % Marcar usuario como terminado
    retract(estadisticas(UserID, Total, Exitosas, Fallidas, TiempoPromedio, _)),
    assertz(estadisticas(UserID, Total, Exitosas, Fallidas, TiempoPromedio, terminado)),
    
    format('🏁 Usuario ~w terminó simulación~n', [UserID]).

% Bucle principal de conversación de un usuario
simular_conversacion(UserID, TiempoFin, PausaEntreConsultas) :-
    simulacion_activa,
    get_time(TiempoActual),
    TiempoActual < TiempoFin,
    !,
    
    % Seleccionar mensaje aleatorio
    mensajes_prueba(Mensajes),
    random_member(Mensaje, Mensajes),
    
    % Enviar consulta al chatbot
    enviar_consulta(UserID, Mensaje),
    
    % Pausa antes de la siguiente consulta
    PausaAleatoria is PausaEntreConsultas + random(3) - 1, % ±1 segundo de variación
    sleep(PausaAleatoria),
    
    % Continuar conversación
    simular_conversacion(UserID, TiempoFin, PausaEntreConsultas).

simular_conversacion(_, _, _).

% Enviar una consulta al chatbot
enviar_consulta(UserID, Mensaje) :-
    chatbot_url(URL),
    get_time(TiempoInicio),
    dict_create(Msg, message, _{ user_id: UserID, text: Mensaje }),
    Payload = _{ message: Msg },
    atom_json_dict(Atom, Payload, []),
    catch(
        (http_post(URL,
                  string(Atom),
                  _Respuesta,
                  [request_header('Content-Type'='application/json')]),
         get_time(TiempoFin),
         TiempoRespuesta is TiempoFin - TiempoInicio,
         actualizar_estadisticas(UserID, exitosa, TiempoRespuesta),
         format('✅ ~w: "~w" → OK (~2f seg)~n', [UserID, Mensaje, TiempoRespuesta])
        ),
        Error,
        (get_time(TiempoFin),
         TiempoRespuesta is TiempoFin - TiempoInicio,
         actualizar_estadisticas(UserID, fallida, TiempoRespuesta),
         format('❌ ~w: "~w" → ERROR: ~w (~2f seg)~n', [UserID, Mensaje, Error, TiempoRespuesta])
        )
    ).

% Actualizar estadísticas de un usuario
actualizar_estadisticas(UserID, Resultado, TiempoRespuesta) :-
    retract(estadisticas(UserID, Total, Exitosas, Fallidas, TiempoPromedio, Estado)),
    NuevoTotal is Total + 1,
    
    (Resultado = exitosa ->
        NuevasExitosas is Exitosas + 1,
        NuevasFallidas = Fallidas
    ;   NuevasExitosas = Exitosas,
        NuevasFallidas is Fallidas + 1
    ),
    
    % Calcular nuevo tiempo promedio
    NuevoTiempoPromedio is ((TiempoPromedio * Total) + TiempoRespuesta) / NuevoTotal,
    
    assertz(estadisticas(UserID, NuevoTotal, NuevasExitosas, NuevasFallidas, NuevoTiempoPromedio, Estado)).

% Mostrar estadísticas actuales
mostrar_estadisticas :-
    format('~n📊 ESTADÍSTICAS DE LA SIMULACIÓN~n'),
    format('=====================================~n'),
    
    findall(estadisticas(U,T,E,F,P,S), estadisticas(U,T,E,F,P,S), Stats),
    
    (Stats = [] ->
        format('⚠️  No hay estadísticas disponibles.~n')
    ;   mostrar_estadisticas_detalladas(Stats),
        mostrar_resumen_global(Stats)
    ).

mostrar_estadisticas_detalladas([]).
mostrar_estadisticas_detalladas([estadisticas(User, Total, Exitosas, Fallidas, TiempoPromedio, Estado)|Rest]) :-
    PorcentajeExito is (Exitosas / max(Total, 1)) * 100,
    format('👤 ~w (~w):~n', [User, Estado]),
    format('   Total consultas: ~w~n', [Total]),
    format('   Exitosas: ~w (~1f%)~n', [Exitosas, PorcentajeExito]),
    format('   Fallidas: ~w~n', [Fallidas]),
    format('   Tiempo promedio: ~2f seg~n~n', [TiempoPromedio]),
    mostrar_estadisticas_detalladas(Rest).

mostrar_resumen_global(Stats) :-
    length(Stats, NumUsuarios),
    sumlist_stats(Stats, TotalConsultas, TotalExitosas, TotalFallidas, TiempoPromedioGlobal),
    
    PorcentajeExitoGlobal is (TotalExitosas / max(TotalConsultas, 1)) * 100,
    
    format('🌍 RESUMEN GLOBAL:~n'),
    format('   Usuarios activos/terminados: ~w~n', [NumUsuarios]),
    format('   Total consultas: ~w~n', [TotalConsultas]),
    format('   Exitosas: ~w (~1f%)~n', [TotalExitosas, PorcentajeExitoGlobal]),
    format('   Fallidas: ~w~n', [TotalFallidas]),
    format('   Tiempo promedio global: ~2f seg~n', [TiempoPromedioGlobal]),
    
    % Calcular throughput
    (TotalConsultas > 0 ->
        ConsultasPorMinuto is TotalConsultas / max(TiempoPromedioGlobal * TotalConsultas / 60, 1),
        format('   Throughput estimado: ~1f consultas/min~n', [ConsultasPorMinuto])
    ;   true),
    
    format('=====================================~n').

% Sumar estadísticas de todos los usuarios
sumlist_stats([], 0, 0, 0, 0).
sumlist_stats([estadisticas(_, Total, Exitosas, Fallidas, TiempoPromedio, _)|Rest], 
              SumTotal, SumExitosas, SumFallidas, PromedioGlobal) :-
    sumlist_stats(Rest, RestTotal, RestExitosas, RestFallidas, RestPromedio),
    SumTotal is Total + RestTotal,
    SumExitosas is Exitosas + RestExitosas,
    SumFallidas is Fallidas + RestFallidas,
    
    % Promedio ponderado por número de consultas
    (SumTotal > 0 ->
        PromedioGlobal is ((TiempoPromedio * Total) + (RestPromedio * RestTotal)) / SumTotal
    ;   PromedioGlobal = 0
    ).

% Predicados de utilidad para pruebas rápidas
prueba_ligera :-
    iniciar_simulacion(5, 2, 3).

prueba_media :-
    iniciar_simulacion(15, 5, 2).

prueba_pesada :-
    iniciar_simulacion(50, 10, 1).

% Ayuda
ayuda :-
    format('🔧 SIMULADOR DE CARGA PARA CHATBOT~n'),
    format('===================================~n~n'),
    format('Comandos principales:~n'),
    format('  iniciar_simulacion(Usuarios, Minutos, PausaSegs)~n'),
    format('  iniciar_simulacion(Usuarios, Minutos, PausaSegs, URL)~n'),
    format('  mostrar_estadisticas/0~n'),
    format('  detener_simulacion/0~n~n'),
    format('Pruebas predefinidas:~n'),
    format('  prueba_ligera/0   - 5 usuarios, 2 min, pausa 3 seg~n'),
    format('  prueba_media/0    - 15 usuarios, 5 min, pausa 2 seg~n'),
    format('  prueba_pesada/0   - 50 usuarios, 10 min, pausa 1 seg~n~n'),
    format('Ejemplo de uso:~n'),
    format('  ?- iniciar_simulacion(10, 3, 2).~n'),
    format('  ?- mostrar_estadisticas.~n'),
    format('  ?- detener_simulacion.~n').
