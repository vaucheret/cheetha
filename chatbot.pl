:- module(chatbot, [start_server/2, iniciar_chat/1]).

:- use_module(library(http/thread_httpd)).
:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_json)).
:- use_module(library(http/http_client)).
:- use_module(library(lists)).
:- use_module(tramite_json).
:- use_module(gramatica).
:- use_module(persistencia).
:- use_module(readenv, [load_dot_env/1]).
:- use_module(library(http/json)).
:- use_module(library(apply), [maplist/3]).
:- use_module(library(listing), [portray_clause/2]).
:- use_module(library(readutil), [read_line_to_string/2]).
:- use_module(library(uuid),[uuid/1]).



:- dynamic current_provider/1.

:- dynamic pregunta_cache/3.



% Configuración de proveedores LLM
% provider_data(ProviderName, ModelName, EnvVarForKey, ApiUrl).
provider_data(openai, "gpt-4o-mini",'OPENAI_API_KEY','https://api.openai.com/v1/chat/completions').
provider_data(deepseek, "deepseek/deepseek-chat-v3.1:free",'OPENROUTER_API_KEY','https://openrouter.ai/api/v1/chat/completions').
provider_data(gemini, "google/gemini-2.0-flash-exp:free",'OPENROUTER_API_KEY','https://openrouter.ai/api/v1/chat/completetions').
provider_data(groq, "openai/gpt-oss-20b",'GROQ_API_KEY','https://api.groq.com/openai/v1/chat/completions').


set_provider(Provider) :-   % openai , deepseek , gemini or groq
    retractall(current_provider(_)),
    assertz(current_provider(Provider)).


start_server(Provider,Port) :-
    set_provider(Provider),
    load_dot_env('.env'),
%    cargar_tramites,
    cargar_tramites_from_url2,
    cargar_preguntas_cache,
    init_db,
    http_server(http_dispatch, [port(Port), workers(6)]).


iniciar_chat(Provider) :-
    set_provider(Provider),
    load_dot_env('.env'),
%    cargar_tramites,
    cargar_tramites_from_url2,
    cargar_preguntas_cache,
    init_db,
    chat_loop.



% ——————————————————————————————————————
% LOOP
% ——————————————————————————————————————


:- http_handler(root(chat), handle_chat, [method(post)]).
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
    format(user_output,"entro identifiacion ~n",[]),
    %%%%%%% log %%%%%%%%
    format(user_output,"datos de identificacion recibidos ~w~n",[In]),
    UserID = In.identificacion,
		format(user_output,"respuesta ~a~n",[In.verificado]),

	  (   In.verificado == true
	  ->
	         format(user_output,"identificacion valida para usuario ~w~n",[UserID]),
	         assert_usuario_identificado(UserID,In.tokenChita,In.validaHasta),
		    retract_tramite_pendiente(UserID, TramiteID, Contexto, P),
		    informacion_tramite(Tramite,Contexto.tramite, Asincronico, _Auth, _),
		    ejecutar_tramite(UserID,Tramite,Contexto.put(topic,"tramites").put(tramiteid,TramiteID),Asincronico,P,"Identificación exitosa. Retomando tu trámite pendiente. «~w». ~s",Tramite, Mensaje),
		    enviar_mensaje_usuario(UserID, Mensaje),
		    reply_json_dict(_{ status: "ok", message: "Identificación exitosa" }, [encoding(utf8)])
		;   reply_json_dict(_{ status: "error", message: "Identificación fallida" }, [encoding(utf8)])
		).


handle_notificacion(Request) :-
    http_read_json_dict(Request, In),
    %%%%%%% log %%%%%%%%
    %format(user_output,"entro notificacion ~n",[]),
    %%%%%%% log %%%%%%%%
		UserID = In.user_id,
		TramiteID = In.tramite_id,
			       Mensaje = In.resultado,
					    %%%%%%% log %%%%%%%%
					    %format(user_output,"con este mensaje ~w~n",[Mensaje]),
					    %%%%%%% log %%%%%%%%
    (
       atom_string(TramiteIDA,TramiteID),
       retract_tramite_en_espera(UserID, Tramite, TramiteIDA,Contexto)
		->
		(    Mensaje.'Accion' == 1
			     -> 
				 cargar_variables_tramite_en_espera(Mensaje.'VariablesPedidas',[Paso|Pasos]),
				 (   estado(UserID,_,_,_) -> assert_tramite_pendiente(UserID, TramiteIDA,Contexto.put(topic,Mensaje.'TopicoKafka'), [Paso|Pasos])
				 ;   
				 assert_estado(UserID, ejecutar_tramite,Contexto.put(topic,Mensaje.'TopicoKafka'), [Paso|Pasos]),
				 generar_pregunta_chatgpt(Tramite, Paso, Pregunta),
				 format(string(Texto),
					"Hola, para continuar con el tramite «~w», necesitamos mas información. ~s", [Tramite, Pregunta])
				 )
			     ;
			     (	 Mensaje.'Accion' == 2
					 ->
				 format(string(Texto),
					"Hola, para completar el tramite «~w», necesitamos que te dirijas al siguiente link  ~s", [Tramite, Mensaje.'Link'])
					 ;
					 (    Mensaje.'Accion' == 4
						      ->
				 format(string(Texto),
					"Hola, el tramite «~w», ha sido completado", [Tramite])
					 ))),
		enviar_mensaje_usuario(UserID, Texto),
		reply_json_dict(_{ status: "ok" }, [encoding(utf8)])
									  
		;   reply_json_dict(_{ status: "error", message: "Trámite no encontrado" }, [encoding(utf8)])
		).

enviar_mensaje_usuario(UserID, Texto) :-
    getenv('PrologURL',PrologURL),
    catch(
        http_post(
            PrologURL,
            json(_{ user_id: UserID, texto: Texto }),
            _,
            [ request_header('Content-Type'='application/json'),
              timeout(5)
            ]
        ),
        E
	%%%%%%% log %%%%%%%%
        ,format(user_output,"❌ Error enviando mensaje a usuario ~w: ~w~n",[UserID,E])
        %%%%%%% log %%%%%%%%
    ).



handle_chat(Request) :-
    http_read_json_dict(Request, In),
    UserID = In.message.user_id,
    Text = In.message.text,
    string_lower(Text,TextLower),

    %%%%%%% log %%%%%%%%
    format(user_output,"pregunta ~s~n",[TextLower]),
    %%%%%%% log %%%%%%%%

    dialogo(UserID,TextLower, Respuesta),
    format(string(RS), "~w", [Respuesta]),

    %%%%%%% log %%%%%%%%
    format(user_output,"responde ~s~n",[RS]),
    %%%%%%% log %%%%%%%%

    set_stream(user_output, encoding(utf8)),
    reply_json_dict(_{ respuesta:RS }, [encoding(utf8)]).

chat_loop :-
    prompt(you),
    read_line_to_string(user_input, Line),
    string_lower(Line,TextLower),					      
    dialogo("toplevel",TextLower, R),
    prompt(me),
    writeln(R),
    chat_loop.



% ——————————————————————————————————————
% NUEVO DIALOGO con  fases
% ——————————————————————————————————————

dialogo(UserID, Line, Respuesta) :-
    estado(UserID, Fase, _, _),
    string_codes(Line, LineS),
    % Cancelar diálogo globalmente
    (   phrase((..., terminar, ...), LineS)
    ->  Respuesta = "Gracias por usar el asistente. ¡Hasta luego!",
        retractall_estado(UserID,_,_,_)
    ;  
    procesar_fase(UserID, Fase, Line, Respuesta)
    ).

% ——————————————————————————————————————
% FALLBACK: Si no hay estado aún
% ——————————————————————————————————————

dialogo(UserID, Line, Respuesta) :-
    %        Contexto = _{historia: [system-"Eres un asistente para trámites"]},
        Contexto = _{historia: []},
        assert_estado(UserID, buscar_tramite, Contexto, []),
	dialogo(UserID, Line, Respuesta).



% TODO: manejar "salir" o "cancelar" en cualquier fase
% TODO: realizar phase de identificación de usuario antes de iniciar trámite
% TODO: manejar multiples tramites en paralelo por usuario
% TODO: poder pausear y reanudar trámites mientras el usuario busca datos 


% ——————————————————————————————————————
% FASE 1: BUSCAR TRAMITE
% ——————————————————————————————————————

procesar_fase(UserID, buscar_tramite, Line, Respuesta) :-
    retract_estado(UserID, buscar_tramite, Contexto, _),


    pendientes_usuario(UserID, Pendientes),

    %%%%%%% log %%%%%%%%
    %format(user_output,"tramites pendientes ~w~n",[Pendientes]),
    %%%%%%% log %%%%%%%%

    append(Contexto.historia, [user-Line], Hist1),
    resolver_intencion_llm( Hist1, Pendientes, D),

    %%%%%%% log %%%%%%%%
    %format(user_output,"accion de la intencion  ~s~n",[D.accion]),
    %format(user_output,"respuesta de la intencion  ~s~n",[D.respuesta]),
    %format(user_output,"resto del json  ~w~n",[D]),
    %%%%%%% log %%%%%%%%

    (
        D.accion == "continuar",
          nonvar(D.tramite_id)
	  %%%%%%% log %%%%%%%%
	  %,format(user_output,"tramite a continuar ~w~n",[D.tramite_id])
	  %%%%%%% log %%%%%%%%
	  ->
	      %%%%%%% log %%%%%%%%
	      %format(user_output,"continuar tramite ~w~n",[D.tramite_id]),
	      %%%%%%% log %%%%%%%%
	      atom_string(TramiteIDA,D.tramite_id),
              retract_tramite_pendiente(UserID, TramiteIDA, CtxPend, Pasos),

	      %%%%%%% log %%%%%%%%
	      %format(user_output,"tramite pendiente a continuar ~w~n",[D.tramite_id]),
	      %%%%%%% log %%%%%%%%
	      
              assert_estado(UserID, confirmar_continuar_tramite, CtxPend, Pasos),
	      informacion_tramite(TramitePendiente, CtxPend.tramite, _,_, _),
	      format(string(Respuesta),
	                      "~s ¿Querés continuar con el trámite «~w»?", [D.respuesta, TramitePendiente])
	  ;
	  D.accion == "nuevo",

	    %%%%%%% log %%%%%%%%
	    %format(user_output,"tramite nuevo a iniciar ~n",[]),
	    %%%%%%% log %%%%%%%%
	    
	    nonvar(D.tramite_nuevo),
	    normalizar_codigo_tramite(D.tramite_nuevo, TramiteCod),

	    %%%%%%% log %%%%%%%%
	    %format(user_output,"tramite nuevo a iniciar ~w~n",[D.tramite_nuevo]),
	    %%%%%%% log %%%%%%%%

	    informacion_tramite(TramiteA,TramiteCod,_,_,_),

	    %%%%%%% log %%%%%%%%n
	    %format(user_output,"tramite nuevo a iniciar ~w~n",[TramiteA]),
	    %%%%%%% log %%%%%%%%
	    
	    tramite_disponible(TramiteA)

	    %%%%%%% log %%%%%%%%
	    %,format(user_output,"tramite nuevo disponible a iniciar ~w~n",[TramiteA])
	    %%%%%%% log %%%%%%%%
	    
	    ->
              format(string(Respuesta),
	         "~s ¿Querés hacer el trámite «~w»?", [D.respuesta, TramiteA]),
	      append(Hist1, [assistant-Respuesta], HistFinal),
              assert_estado(UserID, confirmar_tramite,
			    _{tramite:D.tramite_nuevo, historia:HistFinal}, [])
	    ;
	    D.accion == "preguntar"
	      ->
	    % preguntar
	    %%%%%%% log %%%%%%%%
	    %format(user_output,"preguntar tramite ~n",[]),
	    %%%%%%% log %%%%%%%%
	    
	    Respuesta = D.respuesta ,
	    append(Hist1, [assistant-D.respuesta], HistFinal),	  
			  assert_estado(UserID, buscar_tramite,_{historia:HistFinal}, [])
  			  ;
			  D.accion == "error"
			    ->
				Respuesta = D.respuesta ,
	  		        HistFinal = [assistant-Respuesta],
			  assert_estado(UserID, buscar_tramite,_{historia:HistFinal}, [])
    ).



% ——————————————————————————————————————
% FASE 2: CONFIRMAR TRAMITE
% ——————————————————————————————————————

procesar_fase(UserID, confirmar_tramite, Line, Respuesta) :-
    retract_estado(UserID, confirmar_tramite, Contexto, _),
    append(Contexto.historia, [user-Line], Hist1),
    resolver_intencion_pos_neg(Hist1, D),
    (	D.intent == "confirmar_si"
	  ->
	      informacion_tramite(T, Contexto.tramite, Asincronico,Auth, _),
	      uuid(TramiteID),
	      flujo_tramite(T, P ),
	      (
		  identificado(Auth,UserID)

	      -> 
		  ejecutar_tramite(UserID,T,Contexto.put(topic,"tramites").put(tramiteid,TramiteID),
									   Asincronico,P,"Perfecto, iniciemos el trámite «~w». ~s",T, Respuesta)
	      ;
	      %% log %%%%%%% log %%%%%%%%
	      format(user_output,"usuario no identificado, se solicita identificacion para continuar ~w~n",[UserID]),
	      %% log %%%%%%% log %%%%%%%%
	      solicitar_identificacion(UserID,Resp),
	      %% log %%%%%%% log %%%%%%%%
	      format(user_output,"respuesta de solicitud de identificacion dict ~w~n",[Resp]),
	      %% log %%%%%%% log %%%%%%%%
	      LinkDidComm = Resp.presentationContent,
              sub_atom(LinkDidComm,Before,_,_, "_oob="),
	      Start is Before + 5,
	      sub_atom(LinkDidComm,Start,_,0,OOB),
	      getenv('FLASKURL',FlaskURL),
	      atomic_list_concat(['Por favor identifícate para continuar: ',FlaskURL,'/identificar?oob=',OOB],Respuesta),
              assert_tramite_pendiente(UserID, TramiteID, Contexto.put(topic,"tramites").put(tramiteid,TramiteID).put(auth_required,true), P)
	      )
	      
  ;
       D.intent == "confirmar_no"
	 ->  Respuesta = "De acuerdo, contame entonces qué trámite querés hacer.",
		append(Contexto.historia, [user-Line], NuevaHistNo),
		append(NuevaHistNo, [assistant-"De acuerdo, contame entonces qué trámite querés hacer."], HistFinal),
		assert_estado(UserID, buscar_tramite,
			      _{historia:HistFinal}, [])
	 ;   Respuesta = "Perdón, ¿podés responder sí o no?",
		assert_estado(UserID, confirmar_tramite, Contexto, [])
    ).

% ——————————————————————————————————————
% FASE 2.5 : CONFIRMAR CONTINUAR TRAMITE
% ——————————————————————————————————————

procesar_fase(UserID, confirmar_continuar_tramite, Line, Respuesta) :-
    retract_estado(UserID, confirmar_continuar_tramite, Contexto, P ),
    append(Contexto.historia, [user-Line], Hist1),
    resolver_intencion_pos_neg(Hist1, D),
    (	D.intent == "confirmar_si"
	  ->
              informacion_tramite(T, Contexto.tramite, Asincronico,_Auth,_),
	      ejecutar_tramite(UserID,T,Contexto,Asincronico,P,
			     "Perfecto, continuamos con el trámite «~w». ~s",
			     T, Respuesta)
    ;   D.intent == "confirmar_no"
	  ->  Respuesta = "De acuerdo, contame entonces qué trámite querés hacer.",
	      append(Contexto.historia, [user-Line], NuevaHistNo),
	      append(NuevaHistNo, [assistant-"De acuerdo, contame entonces qué trámite querés hacer."], HistFinal),
              assert_estado(UserID, buscar_tramite,
			    _{historia:HistFinal}, []),
	      assert_tramite_pendiente(UserID, Contexto.tramiteid, Contexto, P)
	  ;   Respuesta = "Perdón, ¿podés responder sí o no?",
              assert_estado(UserID, confirmar_tramite, Contexto, [])
    ).

% ——————————————————————————————————————
% FASE 3 : EJECUTAR TRAMITE
% ——————————————————————————————————————


procesar_fase(UserID, ejecutar_tramite, Line, Respuesta) :-
    retract_estado(UserID, ejecutar_tramite, Contexto, Pasos),
    append(Contexto.historia, [user-Line], Hist1),
    resolver_intencion_cont(Hist1, D),
    (
	D.intent == "pausar_tramite"
	  -> 
	      TramiteID = Contexto.tramiteid,
	      assert_tramite_pendiente(UserID, TramiteID, Contexto, Pasos),
	      Respuesta = "Perfecto 👍 Dejamos el trámite en pausa. Cuando quieras lo retomamos."
	   ;
        D.intent == "cancelar_tramite"
	  ->
	      Respuesta = "De acuerdo, cancelamos el trámite. ¿En qué más te puedo ayudar?"
	  ;
	  % si es continuar o ambiguo, seguimos con el trámite
	  assert_estado(UserID, ejecutar_tramite, Contexto, Pasos),
	  fail
		).


procesar_fase(UserID, ejecutar_tramite, Line, Respuesta) :-
    retract_estado(UserID, ejecutar_tramite, Contexto, [Paso|Restantes]),
    string_codes(Line,LineS),
    informacion_tramite(T, Contexto.tramite, Asincronico,_Auth,_),
    Paso = paso(Id,_,Tipo,_),
        (   extraer_respuesta_por_tipo(Tipo, LineS, Line1)
        ->  assert_dato_tramite(UserID,T,Id,Line1),
	    ejecutar_tramite(UserID,T,Contexto,Asincronico,Restantes,
			     "~w~s",'',Respuesta)
        ;   % Respuesta inválida → repreguntar
            generar_repregunta_chatgpt(T,Paso,Respuesta),
            assert_estado(UserID, ejecutar_tramite,
                           Contexto, [Paso|Restantes])
    ).


% ———————————————————————————————————————————————————————
% Predicados auxiliares de procesamiento de fases
% ———————————————————————————————————————————————————————

identificado(0,_) :- !. % no requiere identificación
identificado(D,UserID) :-
    D \= 0,
    usuario_identificado(UserID,_,Fecha_Expiracion),
    get_time(TimestampActual),
    parse_time(Fecha_Expiracion,TimestampExpiracion),
    (	
	TimestampActual < TimestampExpiracion  % la identificación es válida si no ha expirado
    -> 	true
    ;   % identificación expiró, eliminar registro
	retract_usuario_identificado(UserID,_,_),
	fail
		).
     
solicitar_identificacion(UserID,Dict) :-
    getenv('FLASKURL',FlaskURL),
    atom_concat(FlaskURL, '/identificacion_usuario',WebhookURL),
    format(string(URL), "https://thinknetc3.ddns.net/chita/apihook/api/webhooks/ObtenerDeepLink?Identificacion=~w&URLWebHook=~w", [UserID,WebhookURL]),
    catch(
	http_get(
	    URL,
	    Resp,
	    [ request_header('Content-Type'='application/json')
	    ]
	),
	E
	%%%%%%% log %%%%%%%%
	,format(user_output,"❌ Error solicitando identificación para usuario ~w: ~w~n",[UserID,E])
	 %%%%%%% log %%%%%%%%
    ),
    atom_json_term(String,Resp,[as(string)]),
    atom_json_dict(String, Dict, []).

%    format(user_output,"respuesta de solicitud de identificacion original ~w~n",[Resp]).


ejecutar_tramite(UserID,T,Contexto,Asincronico,Pasos,Caption,Tram,Respuesta) :-
    ( Pasos = [Prox|_]
    ->  generar_pregunta_chatgpt(T,Prox,Pregunta),
	format(string(Respuesta),Caption,[Tram, Pregunta]),
	assert_estado(UserID, ejecutar_tramite,Contexto,Pasos)
    ;
    tramite_completado(UserID,T,Contexto,Asincronico,Respuesta)
    ).

tramite_completado(UserID,T,Contexto,Asincronico,Respuesta) :-
	        guardar_preguntas_cache,
	        TramiteID = Contexto.tramiteid,
	        (   usuario_identificado(UserID,Token, _) -> true ; Token = "" ),
		(   Asincronico == true
		->
		exportar_datos_tramite_kafka(UserID,T,TramiteID,Contexto.topic,"tramitesAsincronicos",Token),
		MensajeKafka = "Tu trámite se está procesando,  te avisaremos cuando esté listo.",
		assert_tramite_en_espera(UserID,T,TramiteID,Contexto)
		;
		exportar_datos_tramite_kafka(UserID,T,TramiteID,Contexto.topic,"tramitesResultados",Token),
                esperar_respuesta_kafka(UserID,T,TramiteID,MensajeKafka)
		),
                format(string(Respuesta),
                       "~s\n\n¿En qué otro trámite te puedo ayudar?",
                       [MensajeKafka]).



% ——————————————————————————————————————
% Detección de Intencione por LLM
% ——————————————————————————————————————


% ——————————————————————————————————————
% Detección flexible de trámite por LLM
% ——————————————————————————————————————

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
        _{tramite_id:ID, tramite:T},
	(   
            tramite_pendiente(UserID, ID, Contexto, _),
	    informacion_tramite(T, Contexto.tramite, _Asincronico,_Auth, _)
	    ),
        Pendientes
    ).

% El usuario escribió: «~s».

resolver_intencion_llm( Historia, Pendientes, Decision) :-
    tramites_disponibles(Tramites),
    format(string(Prompt),
	   "Eres un asistente para trámites. Debes identificar la intención del usuario respecto a los trámites que puede realizar. Si quiere continuar con un trámite pendiente, seleccionar uno de ellos. Si quiere iniciar un trámite nuevo, seleccionar uno de los trámites disponibles. Si no está claro que quiere hacer, preguntar para determinar su intención posiblemente dando una lista de tramites pendientes o disponibles.


Tiene estos trámites pendientes:
~w

y tiene estos Trámites disponibles para iniciar uno nuevo:
(lista de tramites con codigo,nombre y descripcion ~s).


Decidí UNA sola opción de accion y respondé SOLO en JSON:

{
  \"accion\": \"continuar\" | \"nuevo\" | \"preguntar\",
  \"tramite_id\": \"uuid\" | null,
  \"tramite_nuevo\": \"codigo\" | null,
  \"respuesta\": \"texto breve para confirmar si el tramite fue detectado o una  nueva pregunta para indagar al usuario cual es el tramite a realizar o para confirmar si seleccionó uno de los pendientes\"
}",
[ Pendientes, Tramites]),
%    append(Historia, [user-Prompt], H2),
    %    H2 = [user-Prompt],
    H2 = [system-Prompt|Historia],
    (
	call_llm_with_context(H2, R) ->
	(
	    is_json_valid(R) ->
	    (   
		atom_json_dict(R, Decision, [])
	    ;	
	    Decision = _{accion:"continuar",tramite_id:null, respuesta:R}
	    )
	)
	%% (
	%%     atom_json_dict(R, Decision, []) -> true
	%% ;
	%% Decision = _{accion:"continuar",tramite_id:null, respuesta:R}
	%% )
    ;
    Decision = _{accion:"error",tramite_id:null, respuesta:"Lo siento, no pude entender tu respuesta. ¿Podrías aclarar qué trámite te interesa?"}

    ).

is_json_valid(R) :-
    catch(
        (atom_json_dict(R, _, []), true),
        error(syntax_error(_), _),
        fail
    ).

resolver_intencion_pos_neg(Historia,  Decision) :-
    format(string(Prompt),
"El usuario respondió a una confirmación dentro de un trámite.

Debes determinar si la intención es:
- confirmar_si  (afirmación clara)
- confirmar_no  (rechazo claro)
- ambiguo       (no queda claro)

Respondé SOLO en JSON, sin texto adicional:

{
  \"intent\": \"confirmar_si\" | \"confirmar_no\" | \"ambiguo\"
}", []),
    H2 = [system-Prompt|Historia],
    catch(
        (
            call_llm_with_context(H2, R),
            atom_json_dict(R, Decision, [])
        ),
        _,
        Decision = _{intent:"ambiguo"}
    ).


resolver_intencion_cont(Historia, Decision) :-
    format(string(Prompt),
"El usuario está respondiendo durante la ejecución de un trámite.

Determiná la intención principal del usuario. Opciones válidas:

- continuar          (está respondiendo el dato pedido)
- pausar_tramite     (quiere hacerlo después, más tarde, pausar)
- cancelar_tramite   (no quiere seguir con el trámite)
- ambiguo            (no es claro)

Respondé SOLO en JSON:

{
  \"intent\": \"continuar\" | \"pausar_tramite\" | \"cancelar_tramite\" | \"ambiguo\"
}", []),
    H2 = [system-Prompt|Historia],
    catch(
        (
            call_llm_with_context(H2, R),
            atom_json_dict(R, Decision, [])
        ),
        _,
        Decision = _{intent:"ambiguo"}
    ).


% ——————————————————————————————————————
% ChatGPT API integration
% ——————————————————————————————————————


call_llm_with_context(HistMsgs, Response) :-
    current_provider(Provider),
    provider_data(Provider,Model,EnvVarForKey,ApiUrl),
    getenv(EnvVarForKey, Key),
    build_json_dict(HistMsgs,Model,JSONDICT),
    %%% log %%%%%%% log %%%%%%%%
    %format(user_output,"json enviado a llm ~w~n",[JSONDICT]),
    %%% log %%%%%%% log %%%%%%%%
    http_post(ApiUrl,
	      json(JSONDICT),
	      ReplyDict,
	      [
%		  request_header('Content-Type'='application/json'),
		  authorization(bearer(Key))
		  ,
%		
		  application/json
	      ]),
    %%% log %%%%%%% log %%%%%%%%
    %format(user_output,"respuesta original de  llm ~w~n",[ReplyDict]),
    %%% log %%%%%%% log %%%%%%%%
    %% ReplyDict = json(RepyDictA),
    %% format(user_output,"respuesta original de  llm json ~w~n",[RepyDictA.choices]),
    %% RepyDictA.choices = [json(Dict1A)],
    %% Dict1A.message = json(MsgA),	      
    %% format(user_output,"response original  ~w~n",[MsgA.content]),
    
    atom_json_term(Atom,ReplyDict,[as(string)]),
    atom_json_dict(Atom, Dict, []),

    %%% log %%%%%%% log %%%%%%%%
    %format(user_output,"respuesta original como dict  llm ~w~n",[Dict]),
    %%% log %%%%%%% log %%%%%%%%
 
    Dict.choices = [Dict1],
	 Response = Dict1.message.content.

    %%% log %%%%%%% log %%%%%%%%	 
    %format(user_output,"response ~w~n",[Dict1.message.content]),
    %%% log %%%%%%% log %%%%%%%%

    	 
%    extract_gpt_response(ReplyDict, Response),

    %%% log %%%%%%% log %%%%%%%%
    % format(user_output,"response 2 ~w~n",[Response]).
    %%% log %%%%%%% log %%%%%%%%




build_json_dict(Msgs,Model, _{
		model: Model, 
		messages: MessagesList
}) :-
    maplist(to_message_obj, Msgs, MessagesList).


to_message_obj(Role-Text, _{role:SRole, content:Text}) :-
    atom_string(Role, SRole).


%% extract_gpt_response(json(L), Content) :-
%%     member(choices=[json(Choices)],L),
%%     member(message=json(Message),Choices),
%%     member(content=Content,Message).


% ——————————————————————————————————————
% Generación de pregunta desde flujo
% ——————————————————————————————————————

generar_pregunta_chatgpt(Tramite,Paso,Pregunta) :-
    Paso = paso(Codigo, Caption, Tipo, Opciones),
    (
	pregunta_cache(Tramite,Codigo, Pregunta) -> true
    ;
    (	Opciones \== [] -> format(string(Texto)," Por favor incluir en la pregunta estas opciones de respuesta ~w",[Opciones]) ; Texto = "" ),
    atomic_list_concat([
        "Genera una pregunta clara y amable para pedir al usuario un dato dentro del trámite:",
        Tramite, ".\n\n",
        "Código del campo: ", Codigo, "\n",
        "Tipo de dato: ", Tipo, "\n",
        "Descripción o título: ", Caption, "\n\n",
        "Pregunta:", Texto
	      ], PromptChars),atom_string(PromptChars,Prompt),
    catch(
        (
            call_llm_with_context([user-Prompt], Pregunta),
	    assertz(pregunta_cache(Tramite,Codigo,Pregunta))
        ),
        _Error,
        (
            Pregunta = Caption
        )
    )
    ).

generar_repregunta_chatgpt(Tramite,Paso,Pregunta) :-
    Paso = paso(Codigo, Caption, Tipo, Opciones),
    (	Opciones \== [] -> format(string(Texto)," Por favor incluir en la pregunta estas opciones de respuesta ~w",[Opciones]) ; Texto = "" ),
    atomic_list_concat([
        "Por favor reformular una pregunta clara y amable para pedir al usuario un dato dentro del trámite:",
        Tramite, ".\n\n",
        "Código del campo: ", Codigo, "\n",
        "Tipo de dato: ", Tipo, "\n",
        "Descripción o título: ", Caption, "\n\n",
        "Pregunta:", Texto , "Enfatizando que la respuesta debe ser del tipo correcto."
	      ], PromptChars),atom_string(PromptChars,Prompt),
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



guardar_preguntas_cache :-
    open('pregunta_cache.pl', write, S),
    findall(pregunta_cache(T,C,P),pregunta_cache(T,C,P),List),
    portray_clauses(List,S).

portray_clauses([],S) :-
    close(S).

portray_clauses([C|List],S) :-
    portray_clause(S, C),
    portray_clauses(List,S).


cargar_preguntas_cache :-
    (
	exists_file('pregunta_cache.pl') ->
	consult('pregunta_cache.pl')
    ;
    true
    ).

