:- module(chatbot, [start_server/2, iniciar_chat/1]).

:- use_module(library(http/http_server)).
:- use_module(library(http/http_client)).
:- use_module(library(http/http_json)).
:- use_module(library(lists)).
:- use_module(tramite_json).
:- use_module(gramatica).
:- use_module(nlu).
:- use_module(persistencia).
:- use_module(readenv, [load_dot_env/1]).
:- use_module(library(json)).
:- use_module(library(apply), [maplist/3, include/3]).
:- use_module(library(listing), [portray_clause/2]).
:- use_module(library(readutil), [read_line_to_string/2]).
:- use_module(library(uuid), [uuid/1]).
:- use_module(library(date), [parse_time/2]).
:- use_module(library(url)).



:- dynamic current_provider/1.

:- dynamic pregunta_cache/4.

:- discontiguous procesar_fase/4.



% Configuración de proveedores LLM
% provider_data(ProviderName, ModelName, EnvVarForKey, ApiUrl).
% gpt-5-mini se retiró el 2026-12-11.  gpt-6-luna es el más barato y rápido;
% si la calidad conversacional no alcanza, usar gpt-6.1-terra (reemplazo
% oficial de gpt-5-mini, ~10x más caro).

provider_data(ollamalocal, "gemma4:latest", 'OLLAMA_API_KEY', 'http://localhost:11434/v1/chat/completions').
provider_data(gpt4all, "Meta-Llama-3-8B-Instruct.Q4_0.gguf", 'GPT4ALL_API_KEY', 'http://localhost:4891/v1/chat/completions').
provider_data(openai, "gpt-6-luna", 'OPENAI_API_KEY', 'https://api.openai.com/v1/chat/completions').   % alternativa: "gpt-6.1-terra"
provider_data(deepseek, "deepseek/deepseek-v4.1-flash", 'OPENROUTER_API_KEY', 'https://openrouter.ai/api/v1/chat/completions').
provider_data(gemini, "google/gemini-2.5-flash-lite", 'OPENROUTER_API_KEY', 'https://openrouter.ai/api/v1/chat/completions').
provider_data(groq, "openai/gpt-oss-20b", 'GROQ_API_KEY', 'https://api.groq.com/openai/v1/chat/completions').
% anthropic: la Messages API usa otro formato (x-api-key, /v1/messages) y no es
% compatible con call_llm/3; requiere un adaptador propio.

set_provider(Provider) :-   % openai , deepseek , gemini or groq
    retractall(current_provider(_)),
    assertz(current_provider(Provider)).

actualizar_listado_de_tramites :-
    retractall(tramite_json:tramite_codigo_nombre_descripcion_motor(_, _, _, _)),
    retractall(tramite_json:flujo_tramite_codigo_pasos(_, _)),
    cargar_tramite_desde_ril,
    cargar_tramites_from_url2,
    cargar_tramites.

start_server(Provider, Port) :-
    set_provider(Provider),
    load_dot_env('.env'),
    cargar_tramite_desde_ril,
    cargar_tramites_from_url2,
    cargar_tramites,
    cargar_preguntas_cache,
    init_db,
    http_server(http_dispatch, [port(Port), workers(6)]).


iniciar_chat(Provider) :-
    set_provider(Provider),
    load_dot_env('.env'),
    cargar_tramite_desde_ril,
    cargar_tramites_from_url2,
    cargar_tramites,
    cargar_preguntas_cache,
    init_db,
    chat_loop.



% ——————————————————————————————————————
% LOOP
% ——————————————————————————————————————


:- http_handler(root(chat), handle_chat, [method(post)]).
:- http_handler(root(chat_a2a), handle_chat_a2a, [method(post)]).
:- http_handler(root(notificacion_tramite), handle_notificacion, [method(post)]).
:- http_handler(root(identificacion_usuario), handle_identificacion, [method(post)]).
:- http_handler('/.well-known/agent.json', handle_agent_card, []).

handle_agent_card(_Request) :-
    reply_json_dict(_{
                        agent_id: "chita-chatbot-tramites-ar",
                        name: "Asistente de Trámites",
                        description: "Agente conversacional que guía trámites administrativos paso a paso, mantiene estado y permite pausar y reanudar trámites.",
                        protocol: "a2a",
                        version: "1.0.0",
                        language: "es",
                        stateful: true,
                        session_key: "user_id",
                        capabilities: [
                            "buscar_tramite",
                            "iniciar_tramite",
                            "confirmar_tramite",
                            "elegir_modo_tramite",
                            "ejecutar_tramite",
                            "pausar_tramite",
                            "reanudar_tramite",
                            "cancelar_tramite"
                                      ],
                        endpoints: _{
                            chat: _{
                                method: "POST",
                                path: "/chat",
                                input_schema: _{
                                    message: _{
                                        user_id: "string",
                                        text: "string"
                                }
                            },
                                output_schema: _{
                                    respuesta: "string"
                            }
                        }
                    },
                        auth: _{ type: "none" }
    }, [encoding(utf8)]).



handle_identificacion(Request) :-
    http_read_json_dict(Request, In),
    %%%%%%% log %%%%%%%%
    format(user_output, "entro identifiacion ~n", []),
    %%%%%%% log %%%%%%%%
    format(user_output, "datos de identificacion recibidos ~w~n", [In]),
    json_get_case(In, credentialID, CredentialID),
    (   retract_identificacion_pendiente(CredentialID, UserID)
    ->  continuar_identificacion(In, UserID)
    ;   format(user_output, "Aviso: callback sin identificacion pendiente: ~w~n", [CredentialID]),
        reply_json_dict(_{ status: "ok", message: "Sin identificacion pendiente para este credentialID" }, [encoding(utf8)])
    ).

continuar_identificacion(In, UserID) :-
    json_get_case(In, verificada, Verificada),
    format(user_output, "respuesta ~a~n", [Verificada]),

    (   Verificada == true
    ->
            json_get_case(In, token, Token),
            json_get_case(In, vencimiento, Vencimiento),
            assert_usuario_identificado(UserID, Token, Vencimiento),
            (   retract_tramite_en_espera(UserID, CodigoTramite, TramiteID, Contexto)
            ->  Contexto.auth_required = true,
                tramite_codigo_nombre_descripcion_motor(CodigoTramite, Nombre, _, DictMotor),
                flujo_tramite_codigo_pasos(DictMotor.codigochita, P),
                ( estado(UserID, _, _, _) ->
                      assert_tramite_pendiente(UserID, TramiteID, Contexto, P),
                      enviar_resultado(UserID, Contexto,
                                       "Trámite en pausa. Escribí «continuar» para retomarlo.",
                                       "input-required", null)
                ;

                  ejecutar_tramite(UserID, Contexto, P,
                                   "Identificación exitosa. Retomando tu trámite pendiente. «~w». ~s", Nombre, Mensaje),
                  (   P == [] -> EstadoRetoma = "working" ; EstadoRetoma = "input-required"   ),
                  enviar_resultado(UserID, Contexto, Mensaje, EstadoRetoma, null)
                ),
                reply_json_dict(_{ status: "ok", message: "Identificación exitosa" }, [encoding(utf8)])
            ;   reply_json_dict(_{ status: "ok", message: "Identificación registrada; sin trámite pendiente para retomar" }, [encoding(utf8)])
            )

    ;   reply_json_dict(_{ status: "error", message: "Identificación fallida" }, [encoding(utf8)])
    ).


handle_notificacion(Request) :-
    http_read_json_dict(Request, In),
    %%%%%% log %%%%%%%%
    format(user_output, "entro notificacion ~n", []),
    %%%%%% log %%%%%%%%
    UserID = In.user_id,
    TramiteID = In.tramite_id,
    Mensaje = In.resultado,
    %%%%%% log %%%%%%%%
    % format(user_output,"con este mensaje ~w~n",[Mensaje]),
    % format(user_output,"con este usuario y tramite ~w ~w~n",[UserID,TramiteID]),

    %%%%%% log %%%%%%%%
    (
        Mensaje.'Accion' == 5
    ->
            actualizar_listado_de_tramites,
            reply_json_dict(_{ status: "ok" }, [encoding(utf8)])
    ;
        (
            atom_string(TramiteIDA, TramiteID),
            format(user_output, "y con este Tramite ~a~n", [TramiteIDA]),
            retract_tramite_en_espera(UserID, Tramite, TramiteIDA, Contexto)
        ->
                (    Mensaje.'Accion' == 1
                ->
                         format(user_output, "aca entroe ~n", []),
                         ContextoNuevo = Contexto.put(topic, Mensaje.'TopicoKafkaEE')
                                         .put(tramiteid, TramiteIDA)
                                         .put(url, Mensaje.'URLKafkaEE')
                                         .put(topicomotor, Mensaje.'TopicoKafkaMotor')
                                         .put(urlmotor, Mensaje.'URLKafkaMotor')
                                         .put(instanciatramite, Mensaje.'InstanciaTramite')
                                         .put(instanciastep, Mensaje.'InstanciaStep')
                                         .put(codigostep, Mensaje.'CodigoStep')
                                         .put(accion, Mensaje.'Accion'),
                         format(user_output, "aca tambien ~d~n", [Tramite]),
                         cargar_variables_tramite_en_espera(Mensaje.'VariablesPedidas', [Paso|Pasos]),
                         format(user_output, " por aca aca tambien ~d~n", [Tramite]),
                         (   estado(UserID, _, _, _) ->
                                 assert_tramite_pendiente(UserID, TramiteIDA, ContextoNuevo, [Paso|Pasos])
                         ;
                             tramite_codigo_nombre_descripcion_motor(Tramite, Nombre, _, _),
                             format(user_output, "aca fue ~d~n", [Tramite]),
                             ejecutar_tramite(UserID, ContextoNuevo, [Paso|Pasos],
                                              "Hola, para continuar con el tramite «~w», necesitamos mas información. ~s", Nombre, Texto)

                             % assert_estado(UserID, ejecutar_tramite,Contexto.put(topic,Mensaje.'TopicoKafka'), [Paso|Pasos]),
                             % generar_pregunta_chatgpt(Tramite, Paso, Pregunta),
                             % format(string(Texto),
                             % 	"Hola, para continuar con el tramite «~w», necesitamos mas información. ~s", [Tramite, Pregunta])
                         ),
                         Artifacto = null
                ;
                     (  Mensaje.'Accion' == 2
                     ->
                            format(string(Texto),
                                   "Hola, para completar el tramite «~w», necesitamos que te dirijas al siguiente link  ~s", [Tramite, Mensaje.'Link']),
                            Artifacto = null
                     ;
                        (    Mensaje.'Accion' == 4
                        ->
                                 Excepcion = Mensaje.'Excepcion',
                                 (
                                     Excepcion \= "" ->
                                         format(string(Texto), "⚠ Ocurrió un error en el trámite: ~s", [Excepcion]),
                                         Artifacto = null
                                 ;
                                     Respuestas = Mensaje.'Variables',
                                     format(user_output, "con esta respuesta ~w~n", [Respuestas]),
                                     maplist(mensajecontenido, Respuestas, Strings),
                                     atomics_to_string(Strings, Texto),
                                     (   include(variable_con_contenido, Respuestas, Validas),
                                         Validas \= []
                                     ->  maplist(variable_a_part, Validas, Partes),
                                         Artifacto = _{name:"Resultado del trámite", parts:Partes}
                                     ;   Artifacto = null
                                     )
                                 )

                             %		      format(string(Texto),
                             %			     "Hola, el tramite «~w», ha sido completado", [Tramite])
                        )  )
                ),
                enviar_resultado(UserID, Contexto, Texto, "completed", Artifacto),
                reply_json_dict(_{ status: "ok" }, [encoding(utf8)])
        ;   reply_json_dict(_{ status: "error", message: "Trámite no encontrado" }, [encoding(utf8)])
        )
    ).

mensajecontenido(M, S) :-
    format(string(S), "~w descargar de  ~w ~n", [M.'Mensaje', M.'Contenido']).

variable_con_contenido(M) :-
    C = M.'Contenido',
    \+ ( C == "" ; C == '' ; C == null ; C == [] ).

variable_a_part(M, P) :-
    C = M.'Contenido',
    N = M.'Nombre',
    (   N == "" ; N == '' -> Nombre = "resultado" ; Nombre = N   ),
    mimetype_por_extension(C, Mime),
    P = _{kind:"file", name:Nombre, file:_{uri:C, mimeType:Mime}}.

mimetype_por_extension(URI, Mime) :-
    atom_string(URI, A),
    downcase_atom(A, L),
    (   string_concat(_, ".pdf", L) -> Mime = "application/pdf"
    ;   string_concat(_, ".svg", L) -> Mime = "image/svg+xml"
    ;   string_concat(_, ".png", L) -> Mime = "image/png"
    ;   string_concat(_, ".jpg", L) -> Mime = "image/jpeg"
    ;   string_concat(_, ".jpeg", L) -> Mime = "image/jpeg"
    ;   Mime = "application/octet-stream"
    ).


% --- Canal de salida bifurcado por Contexto.canal ---
% whatsapp (default, retrocompatible): POST FLASKURL/enviar_mensaje
% a2a: POST A2A_BRIDGE_URL/internal/update_task

% enviar_mensaje_usuario(UserID, Texto) :-
%     enviar_resultado(UserID, _{canal:whatsapp}, Texto, "input-required", null).

enviar_resultado(UserID, Contexto, Texto, Estado, Artifact) :-
    (   Contexto.get(canal) == a2a ->
            enviar_resultado_a2a(Contexto, Texto, Estado, Artifact)
    ;   enviar_mensaje_whatsapp(UserID, Texto)
    ).

enviar_mensaje_whatsapp(UserID, Texto) :-
    getenv('FLASKURL', FlaskURLLocal),
    atom_concat(FlaskURLLocal, '/enviar_mensaje', PrologURL),
    catch(
        http_post(
            PrologURL,
            json(_{ user_id: UserID, texto: Texto }),
            _,
            [ request_header('Content-Type'='application/json'),
              timeout(5)
            ]
        ),
        E, %%%%%%% log %%%%%%%%
        format(user_output, "❌ Error enviando mensaje a usuario ~w: ~w~n", [UserID, E])
        %%%%%%% log %%%%%%%%
    ).

enviar_resultado_a2a(Contexto, Texto, Estado, Artifact) :-
    (   getenv('A2A_BRIDGE_URL', BridgeURL) -> true ; BridgeURL = 'http://localhost:8001'   ),
    atom_concat(BridgeURL, '/internal/update_task', Endpoint),
    TaskID = Contexto.get(task_id_a2a),
    (   Artifact == null -> ArtifactDict = null ; ArtifactDict = Artifact   ),
    catch(
        http_post(
            Endpoint,
            json(_{ task_id: TaskID, estado: Estado, texto: Texto, artifact: ArtifactDict }),
            _,
            [ request_header('Content-Type'='application/json'),
              timeout(5)
            ]
        ),
        E, format(user_output, "❌ Error enviando update A2A task ~w: ~w~n", [TaskID, E])
    ).



handle_chat(Request) :-
    http_read_json_dict(Request, In),
    UserID = In.message.user_id,
    Text = In.message.text,
    string_lower(Text, TextLower),

    %%%%%%% log %%%%%%%%
    format(user_output, "pregunta ~s~n", [TextLower]),
    %%%%%%% log %%%%%%%%

    (   catch(dialogo(UserID, TextLower, Respuesta0), Error,
              (   format(user_output, "❌ Error en /chat para ~w: ~w~n", [UserID, Error]),
                  Respuesta0 = "Lo siento, hubo un problema interno. ¿Podés repetir tu mensaje?"
              ))
    ->  Respuesta = Respuesta0
    ;   Respuesta = "Lo siento, no pude procesar tu mensaje. ¿Podés repetirlo?"
    ),
    format(string(RS), "~w", [Respuesta]),

    %%%%%%% log %%%%%%%%
    format(user_output, "responde ~s~n", [RS]),
    %%%%%%% log %%%%%%%%

    set_stream(user_output, encoding(utf8)),
    reply_json_dict(_{ respuesta:RS }, [encoding(utf8)]).


% --- Endpoint A2A: el bridge A2A llama acá con {message:{user_id,text}, task_id, context_id} ---
% Devuelve {respuesta, estado, artifact?} donde estado ∈
%   input-required | working | completed | auth-required | canceled
% Marca la sesión con canal:a2a y task_id_a2a para que los push asíncronos
% (handle_notificacion/handle_identificacion) vayan al bridge A2A.

handle_chat_a2a(Request) :-
    http_read_json_dict(Request, In),
    UserID = In.message.user_id,
    Text = In.message.text,
    string_lower(Text, TextLower),
    (   In.get(task_id) =@= null -> TaskID = "" ; TaskID = In.get(task_id)   ),
    %%%%%%% log %%%%%%%%
    format(user_output, "[A2A] pregunta ~s task=~w~n", [TextLower, TaskID]),
    %%%%%%% log %%%%%%%%
    (   estado(UserID, Fase, CtxPrev, _) ->
            (   CtxPrev.get(canal) == a2a -> Ctx0 = CtxPrev
            ;   Ctx0 = CtxPrev.put(canal, a2a).put(task_id_a2a, TaskID)
            )
    ;   Ctx0 = _{historia:[], canal:a2a, task_id_a2a:TaskID}
    ),
    (   estado(UserID, _, _, _) -> retract_estado(UserID, _, _, Pasos),
                                   assert_estado(UserID, Fase, Ctx0, Pasos)
    ;   assert_estado(UserID, buscar_tramite, Ctx0, [])
    ),
    (   catch(dialogo(UserID, TextLower, Respuesta0), Error,
              (   format(user_output, "❌ Error en /chat_a2a para ~w: ~w~n", [UserID, Error]),
                  Respuesta0 = "Error interno en el diálogo"
              ))
    ->  Respuesta = Respuesta0
    ;   Respuesta = "No pude procesar tu mensaje."
    ),
    %%%%%%% log %%%%%%%%
    format(user_output, "respuesta =~w~n", [Respuesta]),
    %%%%%%% log %%%%%%%%

    format(string(RS), "~w", [Respuesta]),
    (   es_mensaje_despedida(Respuesta)
    ->  EstadoA2A = "canceled",
        Artifact = null
    ;   (   estado(UserID, FaseFinal, CtxFinal, _) -> true ; FaseFinal = buscar_tramite, CtxFinal = Ctx0   ),
        estado_a2a(FaseFinal, CtxFinal, EstadoA2A0, Artifact0),
        (   tramite_en_espera(UserID, _, _, CtxEspera),
            get_dict(deep_link_verificacion, CtxEspera, DeepLink)
        ->  EstadoA2A = "auth-required",
            Artifact = _{name:"identificacion-qr",
                         parts:[ _{kind:"text",
                                   text:"Escaneá este QR con la app de identidad para verificarte"},
                                 _{kind:"file", file:_{uri:DeepLink, mimeType:"text/uri-list"}} ]}
        ;   EstadoA2A = EstadoA2A0,
            Artifact = Artifact0
        )
    ),
    %%%%%%% log %%%%%%%%
    format(user_output, "[A2A] responde ~s estado=~w~n", [RS, EstadoA2A]),
    %%%%%%% log %%%%%%%%
    set_stream(user_output, encoding(utf8)),
    (   Artifact == null ->
            reply_json_dict(_{ respuesta:RS, estado:EstadoA2A }, [encoding(utf8)])
    ;   reply_json_dict(_{ respuesta:RS, estado:EstadoA2A, artifact:Artifact }, [encoding(utf8)])
    ).

% Mapeo fase Chita → TaskState A2A
%   buscar/confirmar/ejecutar pidiendo dato → input-required
%   tramite_en_espera (exportado a Kafka)    → working
%   auth_required en contexto                → auth-required
estado_a2a(_, Ctx, "auth-required", null) :-
    Ctx.get(auth_required) == true, !.

estado_a2a(_, Ctx, "working", null) :-
    tramite_en_espera(_, _, _, Ctx), !.

estado_a2a(ejecutar_tramite, _, "input-required", null) :- !.
estado_a2a(elegir_modo_tramite, _, "input-required", null) :- !.
estado_a2a(confirmar_tramite, _, "input-required", null) :- !.
estado_a2a(confirmar_continuar_tramite, _, "input-required", null) :- !.
estado_a2a(buscar_tramite, _, "input-required", null) :- !.
estado_a2a(_, _, "input-required", null).

chat_loop :-
    prompt(you),
    read_line_to_string(user_input, Line),
    string_lower(Line, TextLower),
    dialogo("toplevel", TextLower, R),
    prompt(me),
    writeln(R),
    chat_loop.



% ——————————————————————————————————————
% NUEVO DIALOGO con  fases
% ——————————————————————————————————————

dialogo(UserID, Line, Respuesta) :-
    estado(UserID, Fase, _, _), !,
    (   es_despedida(Line)
    ->  finalizar_conversacion(UserID, Respuesta)
    ;   catch(procesar_fase(UserID, Fase, Line, Respuesta), Error,
              (   format(user_output, "❌ Error en fase ~w para ~w: ~w~n", [Fase, UserID, Error]),
                  Respuesta = "Lo siento, hubo un problema interno. ¿Podés repetir tu mensaje?"
              ))
    ).

% ——————————————————————————————————————
% FALLBACK: Si no hay estado aún
% ——————————————————————————————————————

dialogo(UserID, Line, Respuesta) :-
    %        Contexto = _{historia: [system-"Eres un asistente para trámites"]},
    Contexto = _{historia: []},
    assert_estado(UserID, buscar_tramite, Contexto, []),
    dialogo(UserID, Line, Respuesta).


% Mensaje canonico de despedida.  Se usa para que el proxy A2A pueda
% mapear la despedida a TaskState "canceled" sin depender de la fase.
mensaje_despedida("Gracias por usar el asistente. ¡Hasta luego!").

es_mensaje_despedida(Texto) :-
    mensaje_despedida(Canonico),
    (   string(Texto) -> Texto == Canonico
    ;   atom(Texto) -> atom_string(Texto, Canonico)
    ;   fail
    ).

%!  finalizar_conversacion(+UserID, -Respuesta) is det.
%
%   Cierra la conversacion.  Si el usuario estaba completando un tramite,
%   guarda el progreso como pendiente para poder retomarlo despues.
finalizar_conversacion(UserID, Respuesta) :-
    mensaje_despedida(Respuesta),
    conservar_progreso(UserID),
    retractall_estado(UserID, _, _, _).

% Guarda el estado activo como pendiente, si la fase lo amerita.
conservar_progreso(UserID) :-
    catch(estado(UserID, Fase, Contexto, Pasos), _, fail),
    fase_con_progreso(Fase),
    !,
    guardar_pendiente(UserID, Contexto, Pasos).
conservar_progreso(_).

fase_con_progreso(ejecutar_tramite).
fase_con_progreso(confirmar_continuar_tramite).

%!  guardar_pendiente(+UserID, +Contexto, +Pasos) is det.
%
%   Reemplaza el pendiente del mismo tramite_id para no duplicar hechos.
guardar_pendiente(UserID, Contexto, Pasos) :-
    (   catch(get_dict(tramiteid, Contexto, TramiteID), _, fail),
        TramiteID \== null
    ->  catch(retractall_tramite_pendiente(UserID, TramiteID, _, _), _, true),
        catch(assert_tramite_pendiente(UserID, TramiteID, Contexto, Pasos), Error,
              format(user_output, "❌ No se pudo guardar el pendiente de ~w: ~w~n",
                     [UserID, Error]))
    ;   format(user_output, "⚠️  Sin tramiteid, no se guarda pendiente para ~w~n", [UserID])
    ).

%!  volver_a_buscar(+UserID, +Historia, +Respuesta) is det.
%
%   Cierra el tramite en curso sin ejecutarlo y vuelve a la busqueda.
volver_a_buscar(UserID, Historia, Respuesta) :-
    append(Historia, [assistant-Respuesta], HistFinal),
    assert_estado(UserID, buscar_tramite, _{historia:HistFinal}, []).



% TODO: realizar phase de identificación de usuario antes de iniciar trámite
% TODO: manejar multiples tramites en paralelo por usuario


% ——————————————————————————————————————
% FASE 1: BUSCAR TRAMITE
% ——————————————————————————————————————

procesar_fase(UserID, buscar_tramite, Line, Respuesta) :-
    retract_estado(UserID, buscar_tramite, Contexto, _),
    append(Contexto.historia, [user-Line], Hist1),
    modo_nlu(Modo),
    (   Modo == llm
    ->  buscar_tramite_con_llm(UserID, Hist1, Respuesta)
    ;   (   catch(buscar_tramite_determinista(UserID, Line, Hist1, Contexto, Modo, Respuesta), Error,
                (   format(user_output, "❌ Error en búsqueda determinista para ~w: ~w~n", [UserID, Error]),
                    fail
                ))
        ->  true
        ;   responder_busqueda(UserID, Hist1, [],
                "No pude procesar eso. ¿Me contás de nuevo qué trámite querés hacer?",
                Respuesta)
        )
    ).

% Camino historico: el LLM ve el catalogo completo en cada turno.
buscar_tramite_con_llm(UserID, Hist1, Respuesta) :-
    pendientes_usuario(UserID, Pendientes),
    tramites_disponibles(Tramites),
    catch(resolver_intencion_llm(Hist1, Pendientes, Tramites, D0), Error,
          (   format(user_output, "❌ Error resolviendo intención para ~w: ~w~n", [UserID, Error]),
              D0 = _{accion:"error", tramite_id:null, tramite_nuevo:null,
                     respuesta:"Lo siento, no pude entender tu respuesta. ¿Podrías aclarar qué trámite te interesa?"}
          )),
    decision_accion(D0, Accion),
    (   catch(procesar_busqueda(UserID, Hist1, D0, Accion, Respuesta), Error2,
              (   format(user_output, "❌ Error procesando búsqueda para ~w: ~w~n", [UserID, Error2]),
                  fail
              ))
    ->  true
    ;   responder_busqueda(UserID, Hist1, [],
                           "No pude procesar eso. ¿Me contás de nuevo qué trámite querés hacer?", Respuesta)
    ).

% Camino hibrido: reglas primero, LLM solo si no hay candidato confiable.
buscar_tramite_determinista(UserID, Line, Hist1, Contexto, Modo, Respuesta) :-
    (   get_dict(candidatos, Contexto, Candidatos),
        is_list(Candidatos),
        Candidatos \== []
    ->  (   acto_dialogo(Line, afirmacion),
            Candidatos = [Unico]
        ->  ejecutar_seleccion_candidato(UserID, Unico, Hist1, Respuesta)
        ;   acto_dialogo(Line, afirmacion)
        ->  preguntar_por_candidatos(UserID, Candidatos, Hist1, Respuesta)
        ;   resolver_candidato_previo(Line, Candidatos, Seleccion),
            (   Seleccion = ok(Candidato)
            ->  ejecutar_seleccion_candidato(UserID, Candidato, Hist1, Respuesta)
            ;   Seleccion = varios(CandidatosRestantes)
            ->  preguntar_por_candidatos(UserID, CandidatosRestantes, Hist1, Respuesta)
            ;   buscar_tramite_por_acto(UserID, Line, Hist1, Modo, Respuesta)
            )
        )
    ;   buscar_tramite_por_acto(UserID, Line, Hist1, Modo, Respuesta)
    ).

buscar_tramite_por_acto(UserID, Line, Hist1, Modo, Respuesta) :-
    acto_dialogo(Line, Acto),
    (   Acto == despedida
    ->  finalizar_conversacion(UserID, Respuesta)
    ;   Acto == saludo
    ->  responder_busqueda(UserID, Hist1, [],
            "¡Hola! Soy Chita, tu asistente de trámites. Contame qué trámite querés realizar.", Respuesta)
    ;   Acto == ayuda
    ->  responder_busqueda(UserID, Hist1, [],
            "Puedo ayudarte a iniciar un trámite, continuar uno pendiente o consultar su estado. Por ejemplo: «licencia de conducir», «certificado de nacimiento» o «continuar».", Respuesta)
    ;   Acto == afirmacion
    ->  responder_busqueda(UserID, Hist1, [],
            "¿Qué trámite querés realizar?", Respuesta)
    ;   Acto == negacion
    ->  responder_busqueda(UserID, Hist1, [],
            "De acuerdo. ¿Qué trámite querés realizar?", Respuesta)
    ;   Acto == pausa
    ->  responder_busqueda(UserID, Hist1, [],
            "Cuando quieras seguimos. ¿Qué trámite querés realizar?", Respuesta)
    ;   Acto == cancelacion
    ->  responder_busqueda(UserID, Hist1, [],
            "De acuerdo. ¿Qué trámite querés realizar?", Respuesta)
    ;   Acto == ambiguo
    ->  responder_busqueda(UserID, Hist1, [],
            "No te entendí. ¿Qué trámite querés realizar?", Respuesta)
    ;   Acto == reanudacion
    ->  retomar_pendientes(UserID, Hist1, Respuesta)
    ;   buscar_tramite_por_nombre(UserID, Line, Hist1, Modo, Respuesta)
    ).

buscar_tramite_por_nombre(UserID, Line, Hist1, Modo, Respuesta) :-
    (   intentar_retomar_por_nombre(UserID, Line, Hist1, Respuesta)
    ->  true
    ;   candidatos_tramite(Line, Resultado),
        (   Resultado = unico(Candidato)
        ->  confirmar_tramite_candidato(UserID, Candidato, Hist1, Respuesta)
        ;   Resultado = varios(Candidatos)
        ->  preguntar_por_candidatos(UserID, Candidatos, Hist1, Respuesta)
        ;   Modo == hybrid
        ->  buscar_tramite_con_shortlist(UserID, Line, Hist1, Respuesta)
        ;   responder_busqueda(UserID, Hist1, [],
                "No encontré ese trámite. ¿Me lo describís de otra forma o me decís el nombre completo?", Respuesta)
        )
    ).

% Solo se prioriza un pendiente si el nombre coincide claramente.
intentar_retomar_por_nombre(UserID, Line, Hist1, Respuesta) :-
    pendientes_candidatos(UserID, Pendientes),
    Pendientes \== [],
    candidatos_en_catalogo(Line, Pendientes, Resultado),
    Resultado = unico(Candidato),
    Candidato.puntaje >= 85,
    !,
    retomar_pendiente_candidato(UserID, Candidato, Hist1, Respuesta).

% Fallback hibrido: LLM con pocos candidatos y el historial reciente.
buscar_tramite_con_shortlist(UserID, Line, Hist1, Respuesta) :-
    shortlist_tramites(Line, 8, Shortlist),
    (   lista_candidatos_json(Shortlist, Tramites)
    ->  true
    ;   Tramites = "{}"
    ),
    pendientes_usuario(UserID, Pendientes),
    catch(resolver_intencion_llm(Hist1, Pendientes, Tramites, D0), Error,
          (   format(user_output, "❌ Error resolviendo búsqueda con shortlist para ~w: ~w~n", [UserID, Error]),
              D0 = _{accion:"preguntar", tramite_id:null, tramite_nuevo:null,
                     respuesta:"No encontré ese trámite. ¿Me lo describís de otra forma?"}
          )),
    decision_accion(D0, Accion),
    (   catch(procesar_busqueda(UserID, Hist1, D0, Accion, Respuesta), Error2,
              (   format(user_output, "❌ Error procesando búsqueda con shortlist para ~w: ~w~n", [UserID, Error2]),
                  fail
              ))
    ->  true
    ;   responder_busqueda(UserID, Hist1, [],
            "No encontré ese trámite. ¿Me lo describís de otra forma?", Respuesta)
    ).

preguntar_por_candidatos(UserID, Candidatos, Hist1, Respuesta) :-
    (   Candidatos = [Primero|_],
        get_dict(tipo, Primero, pendiente)
    ->  mensaje_pendientes(Candidatos, Respuesta)
    ;   mensaje_candidatos(Candidatos, Respuesta)
    ),
    responder_busqueda(UserID, Hist1, Candidatos, Respuesta).

confirmar_tramite_candidato(UserID, Candidato, Hist1, Respuesta) :-
    Codigo = Candidato.codigo,
    (   catch(tramite_codigo_nombre_descripcion_motor(Codigo, Nombre, _, _), _, fail)
    ->  format(string(Respuesta), "Encontré este trámite: «~w». ¿Querés iniciarlo?", [Nombre]),
        append(Hist1, [assistant-Respuesta], HistFinal),
        assert_estado(UserID, confirmar_tramite, _{tramite:Codigo, historia:HistFinal}, [])
    ;   responder_busqueda(UserID, Hist1, [],
            "No encontré ese trámite en el catálogo. ¿Me decís el nombre completo?", Respuesta)
    ).

ejecutar_seleccion_candidato(UserID, Candidato, Hist1, Respuesta) :-
    (   get_dict(tipo, Candidato, pendiente)
    ->  retomar_pendiente_candidato(UserID, Candidato, Hist1, Respuesta)
    ;   confirmar_tramite_candidato(UserID, Candidato, Hist1, Respuesta)
    ).

retomar_pendiente_candidato(UserID, Candidato, Hist1, Respuesta) :-
    TramiteID = Candidato.tramite_id,
    (   catch(tramite_pendiente(UserID, TramiteID, Contexto, Pasos), _, fail)
    ->  retract_tramite_pendiente(UserID, TramiteID, Contexto, Pasos),
        catch(tramite_codigo_nombre_descripcion_motor(Contexto.tramite, Nombre, _, _), _, fail),
        format(string(Respuesta), "Trámite pendiente: «~w». ¿Querés retomarlo?", [Nombre]),
        append(Hist1, [assistant-Respuesta], HistFinal),
        put_dict(historia, Contexto, HistFinal, ContextoNuevo),
        assert_estado(UserID, confirmar_continuar_tramite, ContextoNuevo, Pasos)
    ;   responder_busqueda(UserID, Hist1, [],
            "No encontré ese trámite pendiente. ¿Qué trámite querés realizar?", Respuesta)
    ).

retomar_pendientes(UserID, Hist1, Respuesta) :-
    pendientes_candidatos(UserID, Pendientes),
    (   Pendientes == []
    ->  responder_busqueda(UserID, Hist1, [],
            "No tenés trámites pendientes. ¿Qué trámite querés realizar?", Respuesta)
    ;   Pendientes = [Candidato]
    ->  retomar_pendiente_candidato(UserID, Candidato, Hist1, Respuesta)
    ;   mensaje_pendientes(Pendientes, Respuesta),
        responder_busqueda(UserID, Hist1, Pendientes, Respuesta)
    ).

responder_busqueda(UserID, Hist1, Candidatos, Respuesta) :-
    append(Hist1, [assistant-Respuesta], HistFinal),
    put_dict(candidatos, _{historia:HistFinal}, Candidatos, Contexto),
    assert_estado(UserID, buscar_tramite, Contexto, []).

% Variante con mensaje explicito; equivale a unificar Respuesta y delegar.
responder_busqueda(UserID, Hist1, Candidatos, Mensaje, Respuesta) :-
    Respuesta = Mensaje,
    responder_busqueda(UserID, Hist1, Candidatos, Respuesta).

pendientes_candidatos(UserID, Candidatos) :-
    findall(_{tipo:pendiente, tramite_id:TramiteID, codigo:Codigo,
              nombre:Nombre, entidad:Entidad},
            (   tramite_pendiente(UserID, TramiteID, Contexto, _),
                catch(get_dict(tramite, Contexto, Codigo), _, fail),
                catch(tramite_codigo_nombre_descripcion_motor(Codigo, Nombre0, _, Info), _, fail),
                a_texto(Nombre0, Nombre),
                (   is_dict(Info), get_dict(entidad, Info, Entidad0), Entidad0 \== ""
                ->  Entidad = Entidad0
                ;   Entidad = ""
                )
            ),
            Candidatos0),
    sort(Candidatos0, Candidatos).

mensaje_candidatos(Candidatos, Respuesta) :-
    (   Candidatos = [Unico]
    ->  nombre_candidato(Unico, Nombre),
        format(string(Respuesta),
               "Encontré este trámite: «~s». ¿Querés iniciarlo? Respondé sí o no.", [Nombre])
    ;   findall(Linea, linea_candidato(Candidatos, Linea), Lineas),
        atomic_list_concat(Lineas, "\n", Lista),
        format(string(Respuesta),
               "Encontré varias opciones:\n~s\n\n¿Cuál querés? Respondé con el número o el nombre.",
               [Lista])
    ).

mensaje_pendientes(Pendientes, Respuesta) :-
    findall(Linea, linea_candidato(Pendientes, Linea), Lineas),
    atomic_list_concat(Lineas, "\n", Lista),
    format(string(Respuesta),
           "Tenés estos trámites pendientes:\n~s\n\n¿Cuál querés retomar? Respondé con el número o el nombre.",
           [Lista]).

linea_candidato(Candidatos, Linea) :-
    nth1(Indice, Candidatos, Candidato),
    nombre_candidato(Candidato, Nombre0),
    capitalizar(Nombre0, Nombre),
    entidad_candidato(Candidato, Entidad),
    (   Entidad \== ""
    ->  format(string(Linea), "~w) ~s — ~s", [Indice, Nombre, Entidad])
    ;   format(string(Linea), "~w) ~s", [Indice, Nombre])
    ).

nombre_candidato(Candidato, Nombre) :-
    (   get_dict(nombre, Candidato, Nombre0)
    ->  a_texto(Nombre0, Nombre)
    ;   Nombre = "trámite"
    ).

entidad_candidato(Candidato, Entidad) :-
    (   get_dict(entidad, Candidato, Entidad0),
        Entidad0 \== ""
    ->  a_texto(Entidad0, Entidad)
    ;   Entidad = ""
    ).


% ——————————————————————————————————————
% FASE 2: CONFIRMAR TRAMITE
% ——————————————————————————————————————

procesar_fase(UserID, confirmar_tramite, Line, Respuesta) :-
    retract_estado(UserID, confirmar_tramite, Contexto, _),
    append(Contexto.historia, [user-Line], Hist1),
    resolver_confirmacion(Line, Hist1, D),
    decision_intent(D, Intent),
    (   Intent == "confirmar_si"
    ->
          T = Contexto.tramite,
          tramite_codigo_nombre_descripcion_motor(T, Nombre, Descripcion, DictMotor),
          %	informacion_tramite(T, Contexto.tramite, Asincronico,Auth, Descripcion,Aut),
          % aca consultar automatizado
          (   DictMotor.'Automatizado' == true ->
                  % automatizado: mostrar la descripción y preguntar si se ejecuta
                  format(string(Respuesta),
                         "Perfecto, ésta es la información para el trámite «~w»: ~n ~w ~n Instrucciones: ~w ~n ¿Querés que lo ejecute ahora?", [Nombre, Descripcion, DictMotor.'Descripcion']),
                  append(Hist1, [assistant-Respuesta], HistFinal),
                  assert_estado(UserID, elegir_modo_tramite, _{tramite:T, historia:HistFinal}, [])
          ;
              % no es automatizado, dar informacion y seguir con el dialog %%%% Dar Información del Tramite %%%%
              format(string(Respuesta),
                     "Perfecto, ésta es la información para el trámite «~w»: ~n ~w ~n Instrucciones: ~w ~n  En que mas te puedo ayudar?", [Nombre, Descripcion, DictMotor.'Descripcion'])
          )
    ;   Intent == "confirmar_no"
    ->  Respuesta = "De acuerdo, contame entonces qué trámite querés hacer.",
        volver_a_buscar(UserID, Hist1, Respuesta)
    ;   Intent == "pausar_tramite"
    ->  Respuesta = "De acuerdo. Cuando quieras lo retomamos. ¿Qué trámite querés realizar?",
        volver_a_buscar(UserID, Hist1, Respuesta)
    ;   Intent == "cancelar_tramite"
    ->  Respuesta = "De acuerdo, no iniciamos el trámite. ¿Qué trámite querés realizar?",
        volver_a_buscar(UserID, Hist1, Respuesta)
    ;   Intent == "despedida"
    ->  finalizar_conversacion(UserID, Respuesta)
    ;   Respuesta = "Perdón, ¿podés responder sí o no?",
        assert_estado(UserID, confirmar_tramite, Contexto, [])
    ).

% ——————————————————————————————————————
% FASE 2.5 : ELEGIR MODO TRAMITE (confirmar ejecución tras descripción)
% ——————————————————————————————————————

procesar_fase(UserID, elegir_modo_tramite, Line, Respuesta) :-
    retract_estado(UserID, elegir_modo_tramite, Contexto, _),
    append(Contexto.historia, [user-Line], Hist1),
    resolver_confirmacion(Line, Hist1, D),
    decision_intent(D, Intent),
    (   Intent == "confirmar_si"
    -> iniciar_ejecucion_tramite(UserID, Contexto, Respuesta)
    ;   Intent == "confirmar_no"
    ->  Respuesta = "De acuerdo, no lo ejecutamos. ¿Qué trámite querés realizar?",
        volver_a_buscar(UserID, Hist1, Respuesta)
    ;   Intent == "pausar_tramite"
    ->  Respuesta = "De acuerdo. Cuando quieras lo retomamos. ¿Qué trámite querés realizar?",
        volver_a_buscar(UserID, Hist1, Respuesta)
    ;   Intent == "cancelar_tramite"
    ->  Respuesta = "De acuerdo, cancelamos el trámite. ¿Qué trámite querés realizar?",
        volver_a_buscar(UserID, Hist1, Respuesta)
    ;   Intent == "despedida"
    ->  finalizar_conversacion(UserID, Respuesta)
    ; Respuesta = "Perdón, ¿querés que lo ejecute o no?",
      assert_estado(UserID, elegir_modo_tramite, Contexto, [])
    ).

% ——————————————————————————————————————
% FASE 2.6 : CONFIRMAR CONTINUAR TRAMITE
% ——————————————————————————————————————

procesar_fase(UserID, confirmar_continuar_tramite, Line, Respuesta) :-
    retract_estado(UserID, confirmar_continuar_tramite, Contexto, P),
    append(Contexto.historia, [user-Line], Hist1),
    resolver_confirmacion(Line, Hist1, D),
    decision_intent(D, Intent),
    (   Intent == "confirmar_si"
    ->
          T = Contexto.tramite,
          tramite_codigo_nombre_descripcion_motor(T, Nombre, _, _),
          %	informacion_tramite(T, Contexto.tramite, Asincronico,_Auth,_,_),
          ejecutar_tramite(UserID, Contexto, P,
                           "Perfecto, continuamos con el trámite «~w». ~s",
                           Nombre, Respuesta)
    ;   Intent == "confirmar_no"
    ->  guardar_pendiente(UserID, Contexto, P),
        Respuesta = "De acuerdo, contame entonces qué trámite querés hacer.",
        volver_a_buscar(UserID, Hist1, Respuesta)
    ;   Intent == "pausar_tramite"
    ->  guardar_pendiente(UserID, Contexto, P),
        Respuesta = "Perfecto 👍 Dejamos el trámite en pausa. Cuando quieras lo retomamos.",
        volver_a_buscar(UserID, Hist1, Respuesta)
    ;   Intent == "cancelar_tramite"
    ->  Respuesta = "De acuerdo, cancelamos el trámite. ¿Qué trámite querés realizar?",
        volver_a_buscar(UserID, Hist1, Respuesta)
    ;   Intent == "despedida"
    ->  guardar_pendiente(UserID, Contexto, P),
        finalizar_conversacion(UserID, Respuesta)
    ;   Respuesta = "Perdón, ¿podés responder sí o no?",
        assert_estado(UserID, confirmar_continuar_tramite, Contexto, P)
    ).

% ——————————————————————————————————————
% FASE 3 : EJECUTAR TRAMITE
% ——————————————————————————————————————


procesar_fase(UserID, ejecutar_tramite, Line, Respuesta) :-
    retract_estado(UserID, ejecutar_tramite, Contexto, Pasos),
    append(Contexto.historia, [user-Line], Hist1),
    (   Pasos = [Paso|Restantes]
    ->  ejecutar_paso_tramite(UserID, Contexto, Paso, Restantes, Line, Hist1, Respuesta)
    ;   Respuesta = "El trámite ya está en proceso. ¿En qué más te puedo ayudar?"
    ).


ejecutar_paso_tramite(UserID, Contexto, Paso, Restantes, Line, Hist1, Respuesta) :-
    Paso = paso(Id, _, _, Tipo, Opciones),
    T = Contexto.tramite,
    tramite_codigo_nombre_descripcion_motor(T, _, _, DictMotor),
    (   catch(extraer_dato(Tipo, Opciones, Line, ok(Line1)), Error,
              (   format(user_output, "❌ Error extrayendo dato para ~w: ~w~n", [UserID, Error]),
                  fail
              ))
    ->  assert_dato_tramite(UserID, DictMotor.codigochita, Contexto.tramiteid, Id, Line1),
        ejecutar_tramite(UserID, Contexto, Restantes, "~w~s", '', Respuesta)
    ;   resolver_control_paso(Line, Hist1, Decision),
        aplicar_control_paso(Decision, UserID, Contexto, Paso, Restantes, Respuesta)
    ).

%!  resolver_control_paso(+Line, +Historia, -Decision) is det.
%
%   Actos de control durante la recoleccion de datos.  Las reglas cubren las
%   frases completas; en hybrid/llm el LLM solo se consulta si no hubo acto.
resolver_control_paso(Line, Hist1, Decision) :-
    acto_dialogo(Line, Acto),
    (   Acto == despedida
    ->  Decision = despedida
    ;   Acto == pausa
    ->  Decision = pausa
    ;   Acto == cancelacion
    ->  Decision = cancelacion
    ;   Acto == reanudacion
    ->  Decision = continuar
    ;   Acto \== ninguno
    ->  Decision = ambiguo
    ;   modo_nlu(rules)
    ->  Decision = ambiguo
    ;   catch(resolver_intencion_cont(Hist1, D), Error,
              (   format(user_output, "❌ Error resolviendo control para ~w: ~w~n", [Error]),
                  D = _{intent:"ambiguo"}
              )),
        decision_intent(D, Intent),
        (   memberchk(Intent, ["despedida","pausar_tramite","cancelar_tramite"])
        ->  Decision = Intent
        ;   Decision = ambiguo
        )
    ).

aplicar_control_paso(pausa, UserID, Contexto, Paso, Restantes, Respuesta) :-
    !,
    guardar_pendiente(UserID, Contexto, [Paso|Restantes]),
    Respuesta = "Perfecto 👍 Dejamos el trámite en pausa. Cuando quieras lo retomamos.".
aplicar_control_paso(despedida, UserID, Contexto, Paso, Restantes, Respuesta) :-
    !,
    guardar_pendiente(UserID, Contexto, [Paso|Restantes]),
    finalizar_conversacion(UserID, Respuesta).
aplicar_control_paso(cancelacion, _, _, _, _, Respuesta) :-
    !,
    Respuesta = "De acuerdo, cancelamos el trámite. ¿Qué trámite querés realizar?".
aplicar_control_paso(continuar, UserID, Contexto, Paso, Restantes, Respuesta) :-
    !,
    repregunta_deterministica(Paso, Respuesta),
    assert_estado(UserID, ejecutar_tramite, Contexto, [Paso|Restantes]).
aplicar_control_paso(_, UserID, Contexto, Paso, Restantes, Respuesta) :-
    repregunta_deterministica(Paso, Respuesta),
    assert_estado(UserID, ejecutar_tramite, Contexto, [Paso|Restantes]).


procesar_busqueda(UserID, Hist1, D, Accion, Respuesta) :-
    respuesta_decision_segura(D, "¿Qué trámite querés realizar?", RespuestaBase),
    (   Accion == "despedida"
    ->  finalizar_conversacion(UserID, Respuesta)
    ;   Accion == "retomar_pendiente"
    ->  decision_valor(D, tramite_id, null, TramiteIDVal),
        (   TramiteIDVal \== null,
            TramiteIDVal \== "",
            normalizar_tramite_id(TramiteIDVal, TramiteIDA),
            catch(tramite_pendiente(UserID, TramiteIDA, CtxPend, Pasos), _, fail),
            catch(tramite_codigo_nombre_descripcion_motor(CtxPend.tramite, TramitePendiente, _, _), _, fail)
        ->  retract_tramite_pendiente(UserID, TramiteIDA, CtxPend, Pasos),
            put_dict(historia, CtxPend, Hist1, CtxPendNuevo),
            assert_estado(UserID, confirmar_continuar_tramite, CtxPendNuevo, Pasos),
            format(string(Respuesta), "Trámite pendiente: «~w». ¿Querés retomarlo?", [TramitePendiente])
        ;   assert_estado(UserID, buscar_tramite, _{historia:Hist1}, []),
            Respuesta = "No encontré ese trámite pendiente. ¿Qué trámite querés realizar?"
        )
    ;   Accion == "iniciar_nuevo"
    ->  decision_valor(D, tramite_nuevo, null, TramiteNuevoVal),
        (   TramiteNuevoVal \== null,
            TramiteNuevoVal \== "",
            normalizar_codigo_tramite(TramiteNuevoVal, TramiteCod),
            catch(tramite_codigo_nombre_descripcion_motor(TramiteCod, TramiteA, _, _), _, fail)
        ->  format(string(Respuesta), "Encontré este trámite: «~w». ¿Querés iniciarlo?", [TramiteA]),
            append(Hist1, [assistant-Respuesta], HistFinal),
            assert_estado(UserID, confirmar_tramite, _{tramite:TramiteCod, historia:HistFinal}, [])
        ;   assert_estado(UserID, buscar_tramite, _{historia:Hist1}, []),
            Respuesta = "No pude identificar ese trámite. ¿Me decís el nombre completo?"
        )
    ;   Accion == "error"
    ->  Respuesta = RespuestaBase,
        assert_estado(UserID, buscar_tramite, _{historia:[assistant-Respuesta]}, [])
    ;   Respuesta = RespuestaBase,
        append(Hist1, [assistant-Respuesta], HistFinal),
        assert_estado(UserID, buscar_tramite, _{historia:HistFinal}, [])
    ).


% ———————————————————————————————————————————————————————
% Predicados auxiliares de procesamiento de fases
% ———————————————————————————————————————————————————————

%identificado(_,_) :- !. % deshabilidado por ahora
identificado(0, _) :- !. % no requiere identificación
identificado(D, UserID) :-
    D \= 0,
    usuario_identificado(UserID, _, Fecha_Expiracion),
    get_time(TimestampActual),
    parse_time(Fecha_Expiracion, TimestampExpiracion),
    (
        TimestampActual < TimestampExpiracion  % la identificación es válida si no ha expirado
    ->  true
    ;   % identificación expiró, eliminar registro
        retract_usuario_identificado(UserID, _, _),
        fail
    ).

json_get_case(Dict, Key, Val) :-
    get_dict(Key, Dict, Val), !.
json_get_case(Dict, Key, Val) :-
    atom_codes(Key, [C0|Rest]),
    (   C0 >= 65, C0 =< 90 -> C1 is C0 + 32
    ;   C0 >= 97, C0 =< 122 -> C1 is C0 - 32
    ),
    atom_codes(Key2, [C1|Rest]),
    get_dict(Key2, Dict, Val), !.

verificacion_de(Dict, Verif) :-
    json_get_case(Dict, verificacion, Verif),
    \+ json_get_case(Dict, respuestaOK, false).

mensaje_error(Dict, ME) :-
    json_get_case(Dict, msgErr, ME), !.
mensaje_error(_, "").

solicitar_identificacion(UserID, Dict) :-
    uuid(Uuid),
    format(string(UuidStr), "~w", [Uuid]),
    split_string(UuidStr, "-", "", Partes),
    atomics_to_string(Partes, Hex),
    sub_string(Hex, 0, 12, _, Cola),
    string_concat("ch", Cola, CredentialID),
    getenv('FLASKURL', FlaskURL),
    atom_concat(FlaskURL, '/identificacion_usuario', WebhookURL),
    www_form_encode(WebhookURL, WebhookURLEnc),
    ( getenv('SOVRA_PEDIR_VERIFICACION_URL', SovraURL)
    -> true
    ;   SovraURL = 'https://thinknetc3.ddns.net/chitaV2/APISovraV2/api/Sovra/PedirVerificacion'
    ),
    format(string(URL),
           "~w?URLRespuesta=~w&ModoQR=1&Dimension=655",
           [SovraURL, WebhookURLEnc]),
    DCQL =
        _{dcql_query:
          _{credentials:
            [_{id: CredentialID,
               format: "vc+sd-jwt",
               claims:
               [_{path:["Apellido"]},
                _{path:["Nombres"]},
                _{path:["CUIT"]},
                _{path:["FechaNacimiento"]},
                _{path:["Entidad"]}]
            }]
        }},
    ( getenv('SOVRA_TOKEN', T) -> true ; T = 'kjedWBHKJHWEBJXNDLWKED87OWLAKJSBDA' ),
    atom_concat('Bearer ', T, Bearer),
    catch(
        http_post(
            URL,
            json(DCQL),
            Resp,
            [ request_header('Authorization'=Bearer),
              timeout(30),
              json_object(dict)
            ]
        ),
        E, %%%%%%% log %%%%%%%%
        format(user_output, "❌ Error solicitando identificación para usuario ~w: ~w~n", [UserID, E])% ,
        % Resp = _{msgErr:"sin respuesta del servicio de identidad"}
        %  %%%%%%% log %%%%%%%%
    ),
    (   is_dict(Resp)
    ->  Dict = Resp
    ;   catch(atom_json_dict(Resp, Dict, []),
              E2,
              (   format(user_output, "❌ Respuesta no-JSON de PedirVerificacion para usuario ~w: ~w~n", [UserID, E2]),
                  Dict = _{msgErr:"respuesta inválida del servicio de identidad"}
              ))
    ),
    (   verificacion_de(Dict, Verif),
        get_dict(session_id, Verif, _)
    ->  assert_identificacion_pendiente(CredentialID, UserID)
    ;   mensaje_error(Dict, ME),
        format(user_output, "❌ PedirVerificacion rechazada para usuario ~w: ~s~n", [UserID, ME])
    ).


iniciar_ejecucion_tramite(UserID, Contexto, Respuesta) :-
    T = Contexto.tramite,
    tramite_codigo_nombre_descripcion_motor(T, Nombre, _, DictMotor),
    uuid(TramiteID),
    (   getenv('KAFKA_TOPICO_ENVIO', TopicEnvio) -> true
    ;   TopicEnvio = "tramitesPrueba"
    ),
    (   getenv('KAFKA_TOPICO_RESPUESTA', TopicRespuesta) -> true
    ;   TopicRespuesta = "tramitesAsincronicos"
    ),
    (   getenv('KAFKA_BROKER', KafkaBroker) -> true
    ;   KafkaBroker = "66.70.179.213:9092"
    ),
    ContextoNuevo = Contexto.put(topic, TopicEnvio)
                    .put(tramiteid, TramiteID)
                    .put(url, KafkaBroker)
                    .put(topicomotor, TopicRespuesta)
                    .put(urlmotor, KafkaBroker)
                    .put(instanciatramite, -1)
                    .put(instanciastep, -1)
                    .put(codigostep, -1)
                    .put(accion, 3),
    flujo_tramite_codigo_pasos(DictMotor.codigochita, P),
    %		  flujo_tramite(T, P ),
    (
        identificado(DictMotor.loginNecesario, UserID)
    ->
            ejecutar_tramite(UserID,
                             ContextoNuevo, P, "Perfecto, iniciemos el trámite «~w». ~s", Nombre, Respuesta)
    ;
        %% log %%%%%%% log %%%%%%%%
        format(user_output, "usuario no identificado, se solicita identificacion para continuar ~w~n", [UserID]),
        %% log %%%%%%% log %%%%%%%%
        solicitar_identificacion(UserID, Resp),
        %% log %%%%%%% log %%%%%%%%
        format(user_output, "respuesta de solicitud de identificacion dict ~w~n", [Resp]),
        %% log %%%%%%% log %%%%%%%%
        (   verificacion_de(Resp, Verif),
            json_get_case(Verif, authorization_request_uri_ref, OpenIdURI),
            OpenIdURI \== ""
        ->  www_form_encode(OpenIdURI, OpenIdURICod),
            getenv('FLASKURL', FlaskURL),
            atomic_list_concat(['Por favor identifícate para continuar: ', FlaskURL, '/identificar?vp=', OpenIdURICod], Respuesta),
            ContextoEspera = ContextoNuevo.put(auth_required, true).put(deep_link_verificacion, OpenIdURI)
        ;   mensaje_error(Resp, ME0),
            ( sub_string(ME0, 0, 120, _, ME) -> true ; ME = ME0 ),
            format(string(Respuesta),
                   "No pude iniciar la verificación de identidad: ~s. Intentá de nuevo en unos minutos.",
                   [ME]),
            ContextoEspera = ContextoNuevo.put(auth_required, true)
        ),
        assert_tramite_en_espera(UserID, T, TramiteID, ContextoEspera)
    ).


ejecutar_tramite(UserID, Contexto, Pasos, Caption, Tram, Respuesta) :-
    ( Pasos = [Prox|_]
    ->  generar_pregunta_chatgpt(Contexto, Prox, Pregunta),
        format(string(Respuesta), Caption, [Tram, Pregunta]),
        assert_estado(UserID, ejecutar_tramite, Contexto, Pasos)
    ;
      tramite_completado(UserID, Contexto, Respuesta)
    ).

tramite_completado(UserID, Contexto, Respuesta) :-
    guardar_preguntas_cache,
    Tramite = Contexto.tramite,
    tramite_codigo_nombre_descripcion_motor(Tramite, _, _, DictMotor),
    T = DictMotor.codigochita,
    Asincronico = DictMotor.asincronico,
    TramiteID = Contexto.tramiteid,
    (   usuario_identificado(UserID, Token, _) -> true ; Token = ""   ),
    ( Asincronico == true
    ->
          Respuesta = "Tu trámite se está procesando,  te avisaremos cuando esté listo.\n\n¿En qué otro trámite te puedo ayudar?"
    ;
      Respuesta = "Tramite en proceso\n"
    ),
    format(user_output, "antes de exportar ~w~n", [UserID]),
    exportar_datos_tramite_kafka(UserID, T, TramiteID, Token, Contexto),
    assert_tramite_en_espera(UserID, Tramite, TramiteID, Contexto).


% (   Asincronico == true
% ->
% 	exportar_datos_tramite_kafka(UserID,T,TramiteID,Contexto.topic,"tramitesAsincronicos",Token),
% 	MensajeKafka = "Tu trámite se está procesando,  te avisaremos cuando esté listo.",
% 	assert_tramite_en_espera(UserID,Tramite,TramiteID,Contexto)
% ;
% 	exportar_datos_tramite_kafka(UserID,T,TramiteID,Contexto.topic,"tramitesResultados",Token),
% 	esperar_respuesta_kafka(UserID,T,TramiteID,MensajeKafka)
% ),
% format(string(Respuesta),
% 	   "~s\n\n¿En qué otro trámite te puedo ayudar?",
% 	   [MensajeKafka]).



% ——————————————————————————————————————
% Detección de Intencione por LLM
% ——————————————————————————————————————


% ——————————————————————————————————————
% Detección flexible de trámite por LLM
% ——————————————————————————————————————

normalizar_tramite_id(Dato, Codigo) :-
    atom(Dato),
    !,
    Codigo = Dato.

normalizar_tramite_id(Dato, Codigo) :-
    number(Dato),
    catch(atom_number(Codigo, Dato), _, fail).

normalizar_tramite_id(Dato, Codigo) :-
    string(Dato),
    catch(atom_string(Codigo, Dato), _, fail).

normalizar_codigo_tramite(Dato, Codigo) :-
    number(Dato),
    !,
    Codigo = Dato.

normalizar_codigo_tramite(Dato, Codigo) :-
    string(Dato),
    catch(number_string(Codigo, Dato), _, fail).

normalizar_codigo_tramite(Dato, Codigo) :-
    atom(Dato),
    catch(atom_number(Dato, Codigo), _, fail).


pendientes_usuario(UserID, Pendientes) :-
    findall(
        _{tramite_id:ID, tramite:T, entidad:E, categoria:Cat},
        (
            tramite_pendiente(UserID, ID, Contexto, _),
            tramite_codigo_nombre_descripcion_motor(Contexto.tramite, T, _, DictMotor),
            E = DictMotor.get(entidad, ""),
            tramite_json:categoria_de_nombre(T, Cat)
        ),
        L
    ),
    atom_json_dict(Pendientes, _{pendientes:L}, [as(string)]).

% El usuario escribió: «~s».

resolver_intencion_llm(Historia, Pendientes, Tramites, Decision) :-
    format(string(Prompt),
           "Eres un asistente para trámites administrativos argentinos.\nTu tarea es identificar qué trámite quiere realizar el usuario.\n\n=== ESTRATEGIA DE ACOTAMIENTO ===\nSeguí estos pasos en orden:\n\nPASO 1 — Determinar continuar pendiente vs iniciar nuevo:\n  Si hay trámites PENDIENTES y el usuario no aclara su intención,\n  preguntale primero si quiere CONTINUAR uno pendiente o INICIAR algo nuevo.\n\nPASO 2 — Acotar por MUNICIPIO/ENTIDAD:\n  Si hay varios candidatos, revisá el campo \"entidad\" de cada trámite.\n  Preguntale al usuario de qué municipio/entidad es el trámite\n  (ej: \"¿El trámite es para el municipio de Escobar?\",\n   \"¿Es para la Municipalidad o para Perico?\").\n\nPASO 3 — Acotar por CATEGORÍA:\n  Si sigue habiendo varios, preguntá por la categoría del trámite\n  (ej: \"¿Buscás un certificado, una licencia, un permiso o una inscripción?\",\n   \"¿Es un duplicado o una renovación?\").\n\nPASO 4 — Confirmar por NOMBRE:\n  Si quedan pocas opciones, preguntá directamente por el nombre.\n\n=== LISTA DE TRÁMITES PENDIENTES (continuar): ===\n~s\n\n=== LISTA DE TRÁMITES DISPONIBLES (iniciar nuevo): ===\n~s\n\n=== REGLAS ===\n- \"retomar_pendiente\": SOLO para trámites de la lista PENDIENTES. Indicá su \"tramite_id\" (uuid de la sesión pendiente).\n- \"iniciar_nuevo\": SOLO para trámites de la lista DISPONIBLES. Indicá su \"codigo\" como \"tramite_nuevo\".\n- \"despedida\": SOLO si el usuario se está despidiendo (chau, hasta luego, nos vemos, me voy, gracias por todo). Indicá \"respuesta\" con una despedida breve.\n- \"preguntar\": cuando no puedas determinar con certeza. IMPORTANTE: la respuesta debe ser una pregunta ESPECÍFICA de acotamiento según los pasos 1-4 (no una pregunta genérica).\n- Si la lista PENDIENTES está vacía, pasá directamente al paso 2 sin mencionarla.\n- Si la lista DISPONIBLES está vacía, pedí al usuario que describa el trámite con otras palabras.\n- IMPORTANTE: los \"codigo\" y \"tramite_id\" son datos internos que el usuario NO conoce. Nunca los menciones en \"respuesta\": referite a los trámites únicamente por su nombre.\n\nRespondé ÚNICAMENTE en JSON (sin texto adicional):\n\n{\n  \"accion\": \"retomar_pendiente\" | \"iniciar_nuevo\" | \"preguntar\" | \"despedida\",\n  \"tramite_id\": \"uuid\" | null,\n  \"tramite_nuevo\": \"codigo\" | null,\n  \"respuesta\": \"texto breve de la pregunta de acotamiento o confirmación\"\n}\n\n",
           [Pendientes, Tramites]),
    historial_para_llm(Historia, 8, Reciente),
    H2 = [system-Prompt|Reciente],
    (   catch(call_llm_json(H2, R1), Error,
              (   format(user_output, "❌ LLM búsqueda de trámite falló: ~w~n", [Error]),
                  fail
              ))
    ->  normalizarjson(R1, R),
        (   parsear_decision_llm(R, D0)
        ->  normalizar_decision_busqueda(D0, Decision)
        ;   Decision = _{accion:"preguntar", tramite_id:null, tramite_nuevo:null,
                         respuesta:"No pude interpretar tu pedido. ¿Me contás qué trámite querés realizar?"}
        )
    ;   Decision = _{accion:"error", tramite_id:null, tramite_nuevo:null,
                     respuesta:"Lo siento, no pude entender tu respuesta. ¿Podrías aclarar qué trámite te interesa?"}
    ).

%!  historial_para_llm(+Historia, +N, -Reciente) is det.
%
%   Recorta el historial a los ultimos N mensajes para no inflar el prompt.
historial_para_llm(Historia, N, Reciente) :-
    length(Historia, Largo),
    (   Largo =< N
    ->  Reciente = Historia
    ;   Skip is Largo - N,
        length(Prefijo, Skip),
        append(Prefijo, Reciente, Historia)
    ).


%!  normalizarjson(+Texto, -Json) is det.
%
%   Extrae el primer objeto JSON de la respuesta del LLM, aunque venga
%   envuelto en un fence, con texto antes/después o con saltos de línea
%   distintos.
normalizarjson(Texto0, Resp) :-
    (   string(Texto0) -> S0 = Texto0
    ;   atom(Texto0) -> atom_string(Texto0, S0)
    ;   format(string(S0), "~w", [Texto0])
    ),
    string_codes(S0, Codes0),
    (   append(_, [123|Despues], Codes0),
        reverse(Despues, Rev),
        append(_, [125|AntesRev], Rev),
        reverse(AntesRev, Medio),
        append(Medio, [125], Cuerpo),
        RespCodes = [123|Cuerpo]
    ->  string_codes(Resp, RespCodes)
    ;   Resp = S0
    ).

%!  parsear_decision_llm(+Texto, -Dict) is semidet.
parsear_decision_llm(Texto, Dict) :-
    catch(
        (   atom_json_dict(Texto, D0, []),
            is_dict(D0)
        ->  Dict = D0
        ;   fail
        ),
        _,
        fail
    ).

normalizar_decision_busqueda(D0, D) :-
    decision_texto(D0, accion, "preguntar", Accion0),
    (   memberchk(Accion0, ["retomar_pendiente","iniciar_nuevo","preguntar","despedida","error"])
    ->  Accion = Accion0
    ;   Accion = "preguntar"
    ),
    decision_valor(D0, tramite_id, null, TramiteID),
    decision_valor(D0, tramite_nuevo, null, TramiteNuevo),
    respuesta_decision_segura(D0, "¿Qué trámite querés realizar?", Respuesta),
    D = _{accion:Accion, tramite_id:TramiteID,
          tramite_nuevo:TramiteNuevo, respuesta:Respuesta}.

% La respuesta del LLM se muestra solo si pasa el filtro; si no, se usa la
% plantilla determinista.
respuesta_decision_segura(D, Default, Respuesta) :-
    respuesta_decision(D, Default, Respuesta0),
    (   sanitizar_respuesta_llm(Respuesta0, Respuesta1)
    ->  Respuesta = Respuesta1
    ;   Respuesta = Default
    ).

%!  sanitizar_respuesta_llm(+Texto, -Respuesta) is semidet.
%
%   Deja pasar solo texto conversacional corto: sin fences, sin JSON, sin
%   URLs y sin preambulos tipicos.  Si no pasa, el llamador usa la plantilla
%   determinista.
sanitizar_respuesta_llm(Texto0, Respuesta) :-
    catch(a_texto(Texto0, Texto1), _, fail),
    split_string(Texto1, "\n\r\t", " \n\r\t", Partes0),
    quitar_partes_vacias(Partes0, Partes),
    Partes \== [],
    atomics_to_string(Partes, " ", Texto2),
    string_codes(Texto2, Codes0),
    quitar_extremos(Codes0, [34, 39, 96, 42], Codes),
    string_codes(Texto3, Codes),
    normalize_space(string(Texto4), Texto3),
    Texto4 \== "",
    string_length(Texto4, Largo),
    Largo =< 400,
    string_lower(Texto4, Lower),
    \+ sub_string(Lower, _, _, _, "```"),
    \+ sub_string(Lower, _, _, _, "{"),
    \+ sub_string(Lower, _, _, _, "}"),
    \+ sub_string(Lower, _, _, _, "http://"),
    \+ sub_string(Lower, _, _, _, "https://"),
    \+ sub_string(Lower, _, _, _, "como modelo"),
    \+ sub_string(Lower, _, _, _, "as an ai"),
    Respuesta = Texto4.

parsear_decision_intent(Texto, Permitidos, Decision) :-
    (   catch(atom_json_dict(Texto, D0, []), _, fail),
        is_dict(D0),
        get_dict(intent, D0, I0),
        I0 \== null,
        catch(a_texto(I0, I), _, fail),
        memberchk(I, Permitidos)
    ->  Decision = _{intent:I}
    ;   Decision = _{intent:"ambiguo"}
    ).

% Helpers para leer decisiones del LLM sin lanzar existence_error.
a_texto(Texto, String) :-
    (   string(Texto) -> String = Texto
    ;   atom(Texto) -> atom_string(Texto, String)
    ;   number(Texto) -> number_string(Texto, String)
    ;   is_list(Texto) -> catch(string_codes(String, Texto), _, fail)
    ;   format(string(String), "~w", [Texto])
    ).

decision_valor(D, Clave, Default, Valor) :-
    (   is_dict(D), get_dict(Clave, D, V0)
    ->  (   V0 == null -> Valor = Default ; Valor = V0 )
    ;   Valor = Default
    ).

decision_texto(D, Clave, Default, Valor) :-
    (   is_dict(D), get_dict(Clave, D, V0), V0 \== null,
        catch(a_texto(V0, V), _, fail), V \== ""
    ->  Valor = V
    ;   Valor = Default
    ).

respuesta_decision(D, Default, Respuesta) :-
    decision_texto(D, respuesta, Default, Respuesta).

decision_accion(D, Accion) :-
    decision_texto(D, accion, "preguntar", Accion).

decision_intent(D, Intent) :-
    decision_texto(D, intent, "ambiguo", Intent).

%!  resolver_confirmacion(+Line, +Historia, -Decision) is det.
%
%   Resuelve sí/no de forma determinista.  El LLM se consulta solo cuando
%   la utterance completa no es un sí/no claro ni una ambiguedad explicita.
resolver_confirmacion(Line, Historia, D) :-
    acto_dialogo(Line, Acto),
    (   Acto == afirmacion
    ->  D = _{intent:"confirmar_si"}
    ;   Acto == negacion
    ->  D = _{intent:"confirmar_no"}
    ;   Acto == despedida
    ->  D = _{intent:"despedida"}
    ;   Acto == pausa
    ->  D = _{intent:"pausar_tramite"}
    ;   Acto == cancelacion
    ->  D = _{intent:"cancelar_tramite"}
    ;   Acto == ambiguo
    ->  D = _{intent:"ambiguo"}
    ;   modo_nlu(rules)
    ->  D = _{intent:"ambiguo"}
    ;   catch(resolver_intencion_pos_neg(Historia, D0), Error,
              (   format(user_output, "❌ Error resolviendo confirmación: ~w~n", [Error]),
                  D0 = _{intent:"ambiguo"}
              )),
        decision_intent(D0, Intent),
        (   memberchk(Intent, ["confirmar_si","confirmar_no","despedida",
                               "pausar_tramite","cancelar_tramite"])
        ->  D = _{intent:Intent}
        ;   D = _{intent:"ambiguo"}
        )
    ).


resolver_intencion_pos_neg(Historia, Decision) :-
    format(string(Prompt),
           "El usuario respondió a una confirmación dentro de un trámite.\n\nDebes determinar si la intención es:\n- confirmar_si  (afirmación clara)\n   → ej: \"sí\", \"si\", \"dale\", \"ok\", \"confirmo\", \"adelante\", \"correcto\", \"claro que sí\"\n- confirmar_no  (rechazo claro)\n   → ej: \"no\", \"para nada\", \"no gracias\", \"mejor no\", \"otro\", \"equivocado\"\n- pausar_tramite (quiere dejarlo para después)\n   → ej: \"después\", \"más tarde\", \"lo dejamos para otro momento\"\n- cancelar_tramite (no quiere seguir con el trámite)\n   → ej: \"cancelar\", \"no quiero seguir\", \"me arrepentí\"\n- despedida     (el usuario se está despidiendo)\n   → ej: \"chau\", \"hasta luego\", \"nos vemos\", \"me voy\", \"gracias por todo\"\n- ambiguo       (no queda claro, responde con otra pregunta o duda)\n   → ej: \"no sé\", \"tal vez\", \"depende\", \"cuéntame más\", \"y qué implica\", o una pregunta\n\nRespondé SOLO en JSON, sin texto adicional:\n\n{\n  \"intent\": \"confirmar_si\" | \"confirmar_no\" | \"pausar_tramite\" | \"cancelar_tramite\" | \"despedida\" | \"ambiguo\"\n}", []),
    historial_para_llm(Historia, 8, Reciente),
    H2 = [system-Prompt|Reciente],
    (   catch(call_llm_json(H2, R0), Error,
              (   format(user_output, "❌ LLM sí/no falló: ~w~n", [Error]),
                  fail
              ))
    ->  normalizarjson(R0, R),
        parsear_decision_intent(R,
            ["confirmar_si","confirmar_no","pausar_tramite","cancelar_tramite",
             "despedida","ambiguo"], Decision)
    ;   Decision = _{intent:"ambiguo"}
    ).


resolver_intencion_cont(Historia, Decision) :-
    format(string(Prompt),
           "El usuario está respondiendo durante la ejecución de un trámite.\n\nDeterminá la intención principal del usuario. Opciones válidas:\n\n- continuar          → está respondiendo el dato pedido o dando información solicitada\n   ej: \"mi cuit es 20-12345678-9\", \"sí, tengo turno\", \"es para la calle San Martín 123\"\n- pausar_tramite     → quiere hacerlo después, más tarde, pausar, retomar luego\n   ej: \"después\", \"más tarde\", \"lo dejo para luego\", \"pausa\", \"seguimos después\"\n- cancelar_tramite   → no quiere seguir con el trámite, quiere cancelar\n   ej: \"cancelar\", \"darse de baja\", \"no quiero seguir\", \"me arrepentí\", \"dejá así no más\"\n- despedida          → el usuario se está despidiendo\n   ej: \"chau\", \"hasta luego\", \"nos vemos\", \"me voy\", \"gracias por todo\"\n- ambiguo            → no es clara la intención (pregunta, duda, saludo, etc.)\n\nRespondé SOLO en JSON:\n\n{\n  \"intent\": \"continuar\" | \"pausar_tramite\" | \"cancelar_tramite\" | \"despedida\" | \"ambiguo\"\n}", []),
    historial_para_llm(Historia, 8, Reciente),
    H2 = [system-Prompt|Reciente],
    (   catch(call_llm_json(H2, R0), Error,
              (   format(user_output, "❌ LLM control de trámite falló: ~w~n", [Error]),
                  fail
              ))
    ->  normalizarjson(R0, R),
        parsear_decision_intent(R,
            ["continuar","pausar_tramite","cancelar_tramite","despedida","ambiguo"], Decision)
    ;   Decision = _{intent:"ambiguo"}
    ).


% ——————————————————————————————————————
% ChatGPT API integration
% ——————————————————————————————————————


call_llm_with_context(HistMsgs, Response) :-
    call_llm(HistMsgs, _{}, Response).

% Variante para los clasificadores que esperan JSON.  El modo JSON se
% habilita solo en proveedores que lo soportan; en el resto el parseo
% tolerante de normalizarjson/2 hace el trabajo.
call_llm_json(HistMsgs, Response) :-
    call_llm(HistMsgs, _{response_format: _{type:"json_object"}}, Response).

call_llm(HistMsgs, Extra, Response) :-
    current_provider(Provider),
    provider_data(Provider, Model, EnvVarForKey, ApiUrl),
    getenv(EnvVarForKey, Key),
    build_json_dict(HistMsgs, Model, BaseDict),
    (   provider_json_mode(Provider)
    ->  put_dict(Extra, BaseDict, JSONDICT)
    ;   JSONDICT = BaseDict
    ),
    llm_intento(ApiUrl, Key, JSONDICT, 1, Response).

provider_json_mode(openai).
provider_json_mode(deepseek).
provider_json_mode(gemini).
provider_json_mode(groq).

llm_intento(ApiUrl, Key, JSONDICT, Intento, Response) :-
    catch(
        (   http_post(ApiUrl,
                      json(JSONDICT),
                      ReplyDict,
                      [ authorization(bearer(Key)),
                        application/json,
                        timeout(15),
                        status_code(Status)
                      ]),
            (   Status >= 200, Status < 300
            ->  (   llm_extraer_respuesta(ReplyDict, Response)
                ->  true
                ;   throw(error(llm_respuesta_invalida, _))
                )
            ;   throw(error(llm_http_status(Status), _))
            )
        ),
        Error,
        (   format(user_output, "❌ LLM intento ~w falló: ~w~n", [Intento, Error]),
            (   Intento < 2,
                llm_reintentable(Error)
            ->  llm_intento(ApiUrl, Key, JSONDICT, 2, Response)
            ;   fail
            )
        )
    ).

% Se reintenta una vez ante timeout, 429 o 5xx.  Un 4xx distinto de 429
% no se reintenta porque la petición está mal formada.
llm_reintentable(error(llm_http_status(Status), _)) :-
    !,
    (   Status == 429
    ;   Status >= 500
    ).
llm_reintentable(_).

llm_extraer_respuesta(ReplyDict0, Response) :-
    (   is_dict(ReplyDict0)
    ->  Dict = ReplyDict0
    ;   (   string(ReplyDict0) -> Texto = ReplyDict0
        ;   atom(ReplyDict0) -> Texto = ReplyDict0
        ;   % http_post/4 con la opcion application/json devuelve json(Term).
            catch(atom_json_term(Texto, ReplyDict0, [as(string)]), _, fail)
        ),
        catch(atom_json_dict(Texto, Dict0, []), _, fail),
        Dict = Dict0
    ),
    get_dict(choices, Dict, [Choice|_]),
    get_dict(message, Choice, Message),
    get_dict(content, Message, Content0),
    Content0 \== null,
    catch(a_texto(Content0, Content), _, fail),
    Content \== "",
    Response = Content.




build_json_dict(Msgs, Model, _{
                    model: Model,
                    messages: MessagesList
}) :-
    maplist(to_message_obj, Msgs, MessagesList).


to_message_obj(Role-Text, _{role:SRole, content:Text}) :-
    atom_string(Role, SRole).



% ——————————————————————————————————————
% Generación de pregunta desde flujo
% ——————————————————————————————————————

%!  generar_pregunta_chatgpt(+Contexto, +Paso, -Pregunta) is det.
%
%   En modo llm (o hybrid con CHITA_PREGUNTAS_LLM=1) usa el LLM con cache.
%   En el resto de los casos la pregunta es determinista.
generar_pregunta_chatgpt(Contexto, Paso, Pregunta) :-
    (   preguntas_llm_habilitadas
    ->  generar_pregunta_con_cache(Contexto, Paso, Pregunta)
    ;   pregunta_deterministica(Paso, Pregunta)
    ).

generar_pregunta_con_cache(Contexto, Paso, Pregunta) :-
    Tramite = Contexto.tramite,
    tramite_codigo_nombre_descripcion_motor(Tramite, Nombre, _, _),
    Paso = paso(Codigo, NombreCampo, Caption, Tipo, Opciones),
    pregunta_cache_version(Version),
    (   pregunta_cache(Version, Tramite, Codigo, Cacheada),
        sanitizar_pregunta(Cacheada, Pregunta)
    ->  true
    ;   retractall(pregunta_cache(Version, Tramite, Codigo, _)),
        (   catch(generar_pregunta_llm(Nombre, NombreCampo, Caption, Tipo, Opciones, Generada),
                  Error,
                  (   format(user_output, "❌ Error generando pregunta para ~w/~w: ~w~n",
                             [Tramite, Codigo, Error]),
                      fail
                  ))
        ->  Pregunta = Generada,
            assertz(pregunta_cache(Version, Tramite, Codigo, Pregunta))
        ;   pregunta_deterministica(Paso, Pregunta)
        )
    ).

generar_pregunta_llm(Nombre, NombreCampo, Caption, Tipo, Opciones, Pregunta) :-
    (   is_list(Opciones), Opciones \== []
    ->  opciones_legibles(Opciones, TextoOpciones),
        format(string(Texto), " Por favor incluí en la pregunta estas opciones de respuesta: ~s", [TextoOpciones])
    ;   Texto = ""
    ),
    atomic_list_concat([
                           "Genera una pregunta clara y amable para pedir al usuario un dato dentro del trámite: ",
                           Nombre, ".\n\n",
                           "Nombre del campo: ", NombreCampo, "\n",
                           "Tipo de dato: ", Tipo, "\n",
                           "Descripción o título: ", Caption, "\n",
                           "Opciones: ", Texto, "\n\n",
                           "Devolvé solo la pregunta, sin explicaciones ni markdown."
                       ], PromptChars),
    atom_string(PromptChars, Prompt),
    call_llm_with_context([user-Prompt], Generada0),
    sanitizar_pregunta(Generada0, Pregunta).

% Pregunta determinista de respaldo.  Se usa cuando el LLM falla o
% devuelve algo que no parece una pregunta.
pregunta_deterministica(Paso, Pregunta) :-
    Paso = paso(_, NombreCampo, Caption, Tipo, Opciones),
    texto_base(Caption, NombreCampo, Base),
    detalle_por_tipo(Tipo, Opciones, Detalle),
    (   Base == ""
    ->  format(string(Pregunta), "¿Podés indicar el dato? ~s", [Detalle])
    ;   format(string(Pregunta), "~s ~s", [Base, Detalle])
    ).

repregunta_deterministica(Paso, Pregunta) :-
    pregunta_deterministica(Paso, Base),
    format(string(Pregunta), "No pude interpretar tu respuesta. ~s", [Base]).

texto_base(Caption, NombreCampo, Base) :-
    (   Caption \== null, Caption \== "",
        catch(a_texto(Caption, C), _, fail), C \== ""
    ->  Base = C
    ;   NombreCampo \== null,
        catch(a_texto(NombreCampo, Base0), _, fail),
        Base0 \== ""
    ->  Base = Base0
    ;   Base = ""
    ).

detalle_por_tipo(Tipo0, Opciones, Detalle) :-
    (   catch(a_texto(Tipo0, Tipo), _, fail) -> true ; Tipo = "texto" ),
    (   Tipo == "numero" -> Detalle = "Respondé solo con números."
    ;   Tipo == "fecha" -> Detalle = "Indicá la fecha con formato DD/MM/AAAA."
    ;   Tipo == "booleano" -> Detalle = "Respondé «sí» o «no»."
    ;   is_list(Opciones), Opciones \== [] ->
        opciones_legibles(Opciones, TextoOpciones),
        format(string(Detalle), "Elegí una opción: ~s.", [TextoOpciones])
    ;   Detalle = "Contame el dato con tus palabras."
    ).

opciones_legibles(Opciones, Texto) :-
    findall(Etiqueta,
            (   member(O, Opciones),
                etiqueta_opcion(O, Etiqueta0),
                catch(a_texto(Etiqueta0, Etiqueta), _, fail),
                Etiqueta \== ""
            ),
            Etiquetas),
    (   Etiquetas == []
    ->  Texto = "(opciones disponibles)"
    ;   atomic_list_concat(Etiquetas, ", ", Texto)
    ).

etiqueta_opcion(opcion(Valor, Etiqueta), Elegida) :-
    !,
    (   Etiqueta \== "", Etiqueta \== null -> Elegida = Etiqueta
    ;   Elegida = Valor
    ).
etiqueta_opcion(Valor, Valor).

%!  sanitizar_pregunta(+Texto, -Pregunta) is semidet.
%
%   Descarta preámbulos y markdown típicos de los LLM.  Si no pasa el
%   filtro, el llamador usa la plantilla determinista.
sanitizar_pregunta(Texto0, Pregunta) :-
    catch(a_texto(Texto0, Texto1), _, fail),
    split_string(Texto1, "\n\r\t", " \n\r\t", Partes0),
    quitar_partes_vacias(Partes0, Partes),
    Partes \== [],
    atomics_to_string(Partes, " ", Texto2),
    quitar_prefijo(Texto2, "Pregunta:", Texto3),
    quitar_prefijo(Texto3, "Respuesta:", Texto4),
    string_codes(Texto4, Codes0),
    quitar_extremos(Codes0, [34, 39, 96, 42], Codes),
    string_codes(Texto5, Codes),
    split_string(Texto5, "\n\r\t", " \n\r\t", Partes2),
    quitar_partes_vacias(Partes2, Partes3),
    Partes3 \== [],
    atomics_to_string(Partes3, " ", Pregunta),
    Pregunta \== "",
    string_length(Pregunta, Largo),
    Largo =< 600,
    string_lower(Pregunta, Lower),
    \+ sub_string(Lower, _, _, _, "```"),
    \+ (   member(Frase, ["claro, aqui", "claro, aquí", "aqui tienes", "aquí tienes",
                          "aqui esta", "aquí está", "la pregunta es",
                          "**opción", "**opcion", "opción 1", "opción 2", "opción 3",
                          "opcion 1", "opcion 2", "opcion 3",
                          "como modelo", "como asistente",
                          "lo siento", "no puedo ayudar"]),
           sub_string(Lower, _, _, _, Frase)
       ).

quitar_partes_vacias([], []).
quitar_partes_vacias([""|Resto], Limpio) :-
    !,
    quitar_partes_vacias(Resto, Limpio).
quitar_partes_vacias([Parte|Resto], [Parte|Limpio]) :-
    quitar_partes_vacias(Resto, Limpio).

quitar_prefijo(Texto, Prefijo, Resto) :-
    string_lower(Texto, Lower),
    string_lower(Prefijo, PrefijoLower),
    (   sub_string(Lower, 0, _, _, PrefijoLower)
    ->  string_length(PrefijoLower, N),
        sub_string(Texto, N, _, 0, Resto0),
        split_string(Resto0, "", " ", [Resto])
    ;   Resto = Texto
    ).

quitar_extremos([C|Resto], Chars, Limpio) :-
    memberchk(C, Chars),
    !,
    quitar_extremos(Resto, Chars, Limpio).
quitar_extremos(Codes, Chars, Limpio) :-
    reverse(Codes, Rev0),
    quitar_extremos_rev(Rev0, Chars, Rev),
    reverse(Rev, Limpio).

quitar_extremos_rev([C|Resto], Chars, Limpio) :-
    memberchk(C, Chars),
    !,
    quitar_extremos_rev(Resto, Chars, Limpio).
quitar_extremos_rev(Codes, _, Codes).

generar_repregunta_chatgpt(Contexto, Paso, Pregunta) :-
    Tramite = Contexto.tramite,
    tramite_codigo_nombre_descripcion_motor(Tramite, Nombre, _, _),
    Paso = paso(_Codigo, NombreCampo, Caption, Tipo, Opciones),
    ( Opciones \== [] -> format(string(Texto), " Por favor incluir en la pregunta estas opciones de respuesta ~w, opcion(X,Y) significa si el usuario selecciona Y responder X", [Opciones]) ; Texto = "" ),
    atomic_list_concat([
                           "Por favor reformular una pregunta clara y amable para pedir al usuario un dato dentro del trámite:",
                           Nombre, ".\n\n",
                           "Nombre del campo: ", NombreCampo, "\n",
                           "Tipo de dato: ", Tipo, "\n",
                           "Descripción o título: ", Caption, "\n\n",
                           "Pregunta:", Texto, "Enfatizando que la respuesta debe ser del tipo correcto."
                       ], PromptChars), atom_string(PromptChars, Prompt),
    catch(
        (
            call_llm_with_context([user-Prompt], Pregunta)

        ),
        _Error,
        (
            Pregunta = Caption
        )
    ).



% ——————————————————————————————————————
% CACHE
% ——————————————————————————————————————



pregunta_cache_version(2).

guardar_preguntas_cache :-
    Tmp = 'pregunta_cache.pl.tmp',
    (   catch(escribir_cache_temporal(Tmp), Error1,
              (   format(user_output, "❌ Error guardando caché de preguntas: ~w~n", [Error1]),
                  catch(delete_file(Tmp), _, true),
                  fail
              ))
    ->  catch(rename_file(Tmp, 'pregunta_cache.pl'), Error2,
              (   format(user_output, "❌ Error renombrando caché de preguntas: ~w~n", [Error2]),
                  catch(delete_file(Tmp), _, true)
              ))
    ;   true
    ).

escribir_cache_temporal(Tmp) :-
    pregunta_cache_version(V),
    findall(pregunta_cache(V, T, C, P), pregunta_cache(V, T, C, P), List),
    setup_call_cleanup(
        open(Tmp, write, S, [encoding(utf8)]),
        portray_clauses(List, S),
        close(S)
    ).

portray_clauses([], _).
portray_clauses([C|List], S) :-
    portray_clause(S, C),
    portray_clauses(List, S).


cargar_preguntas_cache :-
    (   exists_file('pregunta_cache.pl')
    ->  catch(cargar_cache_archivo('pregunta_cache.pl'), Error,
              format(user_output, "⚠️ No se pudo cargar pregunta_cache.pl: ~w~n", [Error]))
    ;   true
    ).

cargar_cache_archivo(Archivo) :-
    setup_call_cleanup(
        open(Archivo, read, S, [encoding(utf8)]),
        leer_cache(S),
        close(S)
    ).

leer_cache(S) :-
    catch(read(S, T), Error,
          (   format(user_output, "⚠️ Entrada inválida en pregunta_cache.pl: ~w~n", [Error]),
              T = end_of_file
          )),
    (   T == end_of_file
    ->  true
    ;   (   T = pregunta_cache(V, Tram, Cod, Preg),
            pregunta_cache_version(V),
            sanitizar_pregunta(Preg, PreguntaLimpia)
        ->  assertz(pregunta_cache(V, Tram, Cod, PreguntaLimpia))
        ;   true
        ),
        leer_cache(S)
    ).

