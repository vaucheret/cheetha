:- module(chatbot, [start_server/2, iniciar_chat/1]).

:- use_module(library(http/http_server)).
:- use_module(library(http/http_client)).
:- use_module(library(lists)).
:- use_module(tramite_json).
:- use_module(gramatica).
:- use_module(persistencia).
:- use_module(readenv, [load_dot_env/1]).
:- use_module(library(json)).
:- use_module(library(apply), [maplist/3]).
:- use_module(library(listing), [portray_clause/2]).
:- use_module(library(readutil), [read_line_to_string/2]).
:- use_module(library(uuid),[uuid/1]).
:- use_module(library(date), [parse_time/2]).



:- dynamic current_provider/1.

:- dynamic pregunta_cache/3.



% Configuración de proveedores LLM
% provider_data(ProviderName, ModelName, EnvVarForKey, ApiUrl).

provider_data(ollamalocal, "gemma4:latest",'OLLAMA_API_KEY','http://localhost:11434/v1/chat/completions').
provider_data(gpt4all, "Meta-Llama-3-8B-Instruct.Q4_0.gguf",'GPT4ALL_API_KEY','http://localhost:4891/v1/chat/completions').
provider_data(openai, "gpt-5-mini",'OPENAI_API_KEY','https://api.openai.com/v1/chat/completions').
provider_data(deepseek, "deepseek/deepseek-chat-v3.1:free",'OPENROUTER_API_KEY','https://openrouter.ai/api/v1/chat/completions').
provider_data(gemini, "google/gemini-2.0-flash-exp:free",'OPENROUTER_API_KEY','https://openrouter.ai/api/v1/chat/completetions').
provider_data(groq, "openai/gpt-oss-20b",'GROQ_API_KEY','https://api.groq.com/openai/v1/chat/completions').
provider_data(anthropic, "claude-3.0",'ANTHROPIC_API_KEY','https://api.anthropic.com/v1/complete').

set_provider(Provider) :-   % openai , deepseek , gemini or groq
    retractall(current_provider(_)),
    assertz(current_provider(Provider)).

actualizar_listado_de_tramites :-
    retractall(tramite_json:tramite_codigo_nombre_descripcion_motor(_,_,_,_)),
    retractall(tramite_json:flujo_tramite_codigo_pasos(_,_)),
    cargar_tramite_desde_ril,
    cargar_tramites_from_url2,
    cargar_tramites.

start_server(Provider,Port) :-
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
    format(user_output,"entro identifiacion ~n",[]),
    %%%%%%% log %%%%%%%%
    format(user_output,"datos de identificacion recibidos ~w~n",[In]),
    UserID = In.identificacion,
    format(user_output,"respuesta ~a~n",[In.verificado]),
    
    (   In.verificado == true
    ->
	format(user_output,"identificacion valida para usuario ~w~n",[UserID]),
	assert_usuario_identificado(UserID,In.tokenChita,In.validaHasta),
	%		 retract_tramite_pendiente(UserID, TramiteID, Contexto, P),
	retract_tramite_en_espera(UserID,CodigoTramite,TramiteID, Contexto),
	Contexto.auth_required = true,
	tramite_codigo_nombre_descripcion_motor(CodigoTramite,Nombre,_,DictMotor),
	flujo_tramite_codigo_pasos(DictMotor.codigochita, P),
	%	flujo_tramite(T, P),
	%	informacion_tramite(Tramite,Contexto.tramite, Asincronico, _Auth, _,_),
	( estado(UserID,_,_,_) ->
	  assert_tramite_pendiente(UserID, TramiteID, Contexto, P)
	;
	  
	  ejecutar_tramite(UserID,Contexto,P,
			   "Identificación exitosa. Retomando tu trámite pendiente. «~w». ~s",Nombre, Mensaje),
	  enviar_resultado(UserID, Contexto, Mensaje, "input-required", null)
	),
	reply_json_dict(_{ status: "ok", message: "Identificación exitosa" }, [encoding(utf8)])
    
    ;   reply_json_dict(_{ status: "error", message: "Identificación fallida" }, [encoding(utf8)])
    ).


handle_notificacion(Request) :-
    http_read_json_dict(Request, In),
    %%%%%% log %%%%%%%%
    format(user_output,"entro notificacion ~n",[]),
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
	    atom_string(TramiteIDA,TramiteID),
	    format(user_output,"y con este Tramite ~a~n",[TramiteIDA]),
	    retract_tramite_en_espera(UserID, Tramite, TramiteIDA,Contexto)
	->
	    (    Mensaje.'Accion' == 1
	    ->
		 format(user_output,"aca entroe ~n",[]),
		 ContextoNuevo = Contexto.put(topic,Mensaje.'TopicoKafkaEE')
	    .put(tramiteid,TramiteIDA)
	    .put(url,Mensaje.'URLKafkaEE')
	    .put(topicomotor,Mensaje.'TopicoKafkaMotor')
	    .put(urlmotor,Mensaje.'URLKafkaMotor')
	    .put(instanciatramite,Mensaje.'InstanciaTramite')
	    .put(instanciastep,Mensaje.'InstanciaStep')
	    .put(codigostep,Mensaje.'CodigoStep')
	    .put(accion,Mensaje.'Accion'),
		 format(user_output,"aca tambien ~d~n",[Tramite]),
		 cargar_variables_tramite_en_espera(Mensaje.'VariablesPedidas',[Paso|Pasos]),
		 format(user_output," por aca aca tambien ~d~n",[Tramite]),
		 (   estado(UserID,_,_,_) ->
		     assert_tramite_pendiente(UserID, TramiteIDA,ContextoNuevo, [Paso|Pasos])
		 ;
		     tramite_codigo_nombre_descripcion_motor(Tramite,Nombre,_,_),
		     format(user_output,"aca fue ~d~n",[Tramite]),
		     ejecutar_tramite(UserID,ContextoNuevo,[Paso|Pasos],
				      "Hola, para continuar con el tramite «~w», necesitamos mas información. ~s",Nombre, Texto)
		 
		 % assert_estado(UserID, ejecutar_tramite,Contexto.put(topic,Mensaje.'TopicoKafka'), [Paso|Pasos]),
		 % generar_pregunta_chatgpt(Tramite, Paso, Pregunta),
		 % format(string(Texto),
		 % 	"Hola, para continuar con el tramite «~w», necesitamos mas información. ~s", [Tramite, Pregunta])
		 )
	    ;
		 (	 Mensaje.'Accion' == 2
		 ->
			 format(string(Texto),
				"Hola, para completar el tramite «~w», necesitamos que te dirijas al siguiente link  ~s", [Tramite, Mensaje.'Link'])
		 ;
			 (    Mensaje.'Accion' == 4
			 ->
			      Excepcion = Mensaje.'Excepcion',
			      (
				  Excepcion \= "" ->
				  format(string(Texto),"⚠ Ocurrió un error en el trámite: ~s",[Excepcion])
			      ;
				  Respuestas = Mensaje.'Variables',
				  format(user_output,"con esta respuesta ~w~n",[Respuestas]),
				  maplist(mensajecontenido, Respuestas, Strings),
				  atomics_to_string(Strings,Texto)
			      )
			 
			 %		      format(string(Texto),
			 %			     "Hola, el tramite «~w», ha sido completado", [Tramite])
			 ))
	    ),
	    enviar_resultado(UserID, Contexto, Texto, "completed", null),
	    reply_json_dict(_{ status: "ok" }, [encoding(utf8)])
	;   reply_json_dict(_{ status: "error", message: "Trámite no encontrado" }, [encoding(utf8)])
	)
    ).

mensajecontenido(M,S) :-
    format(string(S),"~w descargar de  ~w ~n",[M.'Mensaje',M.'Contenido']).    


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
    getenv('FLASKURL',FlaskURLLocal),
    atom_concat(FlaskURLLocal, '/enviar_mensaje',PrologURL),
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

enviar_resultado_a2a(Contexto, Texto, Estado, Artifact) :-
    (   getenv('A2A_BRIDGE_URL', BridgeURL) -> true ; BridgeURL = 'http://localhost:8001' ),
    atom_concat(BridgeURL, '/internal/update_task', Endpoint),
    TaskID = Contexto.get(task_id_a2a),
    (   Artifact == null -> ArtifactDict = null ; ArtifactDict = Artifact ),
    catch(
        http_post(
            Endpoint,
            json(_{ task_id: TaskID, estado: Estado, texto: Texto, artifact: ArtifactDict }),
            _,
            [ request_header('Content-Type'='application/json'),
              timeout(5)
            ]
        ),
        E
	 ,format(user_output,"❌ Error enviando update A2A task ~w: ~w~n",[TaskID,E])
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
    (   In.get(task_id) =@= null -> TaskID = "" ; TaskID = In.get(task_id) ),
    %%%%%%% log %%%%%%%%
    format(user_output,"[A2A] pregunta ~s task=~w~n",[TextLower,TaskID]),
    %%%%%%% log %%%%%%%%
    (   estado(UserID, Fase, CtxPrev, _) ->
        (   CtxPrev.get(canal) == a2a -> Ctx0 = CtxPrev
        ;   Ctx0 = CtxPrev.put(canal, a2a).put(task_id_a2a, TaskID)
        )
    ;   Ctx0 = _{historia:[], canal:a2a, task_id_a2a:TaskID}
    ),
    (   estado(UserID, _, _, _) -> retract_estado(UserID, _, _, Pasos),
				   assert_estado(UserID, Fase, Ctx0,Pasos)
    ;   assert_estado(UserID, buscar_tramite, Ctx0, [])
    ),
    (   catch(dialogo(UserID, TextLower, Respuesta), _, Respuesta = "Error interno en el diálogo") ->
        true
    ;   Respuesta = "No pude procesar tu mensaje."
    ),
    %%%%%%% log %%%%%%%%
    format(user_output,"respuesta =~w~n",[Respuesta]),
    %%%%%%% log %%%%%%%%
    
    format(string(RS), "~w", [Respuesta]),
    (   estado(UserID, FaseFinal, CtxFinal, _) -> true ; FaseFinal = buscar_tramite, CtxFinal = Ctx0 ),
    estado_a2a(FaseFinal, CtxFinal, EstadoA2A, Artifact),
    %%%%%%% log %%%%%%%%
    format(user_output,"[A2A] responde ~s estado=~w~n",[RS,EstadoA2A]),
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
    string_lower(Line,TextLower),					      
    dialogo("toplevel",TextLower, R),
    prompt(me),
    writeln(R),
    chat_loop.



% ——————————————————————————————————————
% NUEVO DIALOGO con  fases
% ——————————————————————————————————————

dialogo(UserID, Line, Respuesta) :-
    estado(UserID, Fase, _, _),!,
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
        D.accion == "retomar_pendiente",
	nonvar(D.tramite_id)
    %%%%%%% log %%%%%%%%
    %,format(user_output,"tramite a continuar ~w~n",[D.tramite_id])
    %%%%%%% log %%%%%%%%
    ->
	%%%%%%% log %%%%%%%%
	%format(user_output,"continuar tramite ~w~n",[D.tramite_id]),
	%%%%%%% log %%%%%%%%
	normalizar_tramite_id(D.tramite_id, TramiteIDA),
	%	      atom_string(TramiteIDA,D.tramite_id),
	retract_tramite_pendiente(UserID, TramiteIDA, CtxPend, Pasos),

	%%%%%%% log %%%%%%%%
	%format(user_output,"tramite pendiente a continuar ~w~n",[D.tramite_id]),
	%%%%%%% log %%%%%%%%
	
	assert_estado(UserID, confirmar_continuar_tramite, CtxPend, Pasos),
	tramite_codigo_nombre_descripcion_motor(CtxPend.tramite, TramitePendiente,_,_),
	
	%	      informacion_tramite(TramitePendiente, CtxPend.tramite, _,_, _,_),
	format(string(Respuesta),
	       "~s Tramite a continuar:  «~w»", [D.respuesta, TramitePendiente])
    ;
	D.accion == "iniciar_nuevo",

	%%%%%%% log %%%%%%%%
	%format(user_output,"tramite nuevo a iniciar ~n",[]),
	%%%%%%% log %%%%%%%%
	
	nonvar(D.tramite_nuevo),
	normalizar_codigo_tramite(D.tramite_nuevo, TramiteCod),

	%%%%%%% log %%%%%%%%
	%format(user_output,"tramite nuevo a iniciar ~w~n",[D.tramite_nuevo]),
	%%%%%%% log %%%%%%%%

	tramite_codigo_nombre_descripcion_motor(TramiteCod, TramiteA,_,_)

    %	    informacion_tramite(TramiteA,TramiteCod,_,_,_,_),

    %%%%%%% log %%%%%%%%n
    %format(user_output,"tramite nuevo a iniciar ~w~n",[TramiteA]),
    %%%%%%% log %%%%%%%%
    
    %	    tramite_disponible(TramiteA)

    %%%%%%% log %%%%%%%%
    %,format(user_output,"tramite nuevo disponible a iniciar ~w~n",[TramiteA])
    %%%%%%% log %%%%%%%%
    
    ->
	format(string(Respuesta),
	       "~s TRÁMITE: «~w» ¿confirma?", [D.respuesta, TramiteA]),
	append(Hist1, [assistant-Respuesta], HistFinal),
	assert_estado(UserID, confirmar_tramite,
		      _{tramite:TramiteCod, historia:HistFinal}, [])
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
	T = Contexto.tramite,
	tramite_codigo_nombre_descripcion_motor(T,Nombre,Descripcion,DictMotor),
	%	informacion_tramite(T, Contexto.tramite, Asincronico,Auth, Descripcion,Aut),
	% aca consultar automatizado
	(	  DictMotor.'Automatizado' == true ->
		  format(string(Respuesta),
			 "Este trámite se puede ejecutar automáticamente. ¿Querés que te dé una descripción primero o que iniciemos la ejecución?", []),
		  append(Hist1, [assistant-Respuesta], HistFinal),
		  assert_estado(UserID, elegir_modo_tramite, Contexto.put(historia, HistFinal), [])
	;
		  % no es automatizado, dar informacion y seguir con el dialog %%%% Dar Información del Tramite %%%%
		  format(string(Respuesta),
			 "Perfecto, ésta es la información para el trámite «~w»: ~n ~w ~n Instrucciones: ~w ~n  En que mas te puedo ayudar?",[Nombre, Descripcion,DictMotor.'Descripcion'])
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
% FASE 2.5 : ELEGIR MODO TRAMITE (descripción vs ejecutar)
% ——————————————————————————————————————

procesar_fase(UserID, elegir_modo_tramite, Line, Respuesta) :-
    retract_estado(UserID, elegir_modo_tramite, Contexto, _),
    append(Contexto.historia, [user-Line], Hist1),
    (	  Contexto.get(post_descripcion) == true
    ->	  % ya se mostró la descripción, ahora es sí/no para ejecutar
	  resolver_intencion_pos_neg(Hist1, D),
	  (	D.intent == "confirmar_si"
	  ->	iniciar_ejecucion_tramite(UserID, Contexto, Respuesta)
	  ;	D.intent == "confirmar_no"
	  ->	Respuesta = "De acuerdo, ¿en qué más te puedo ayudar?",
		append(Hist1, [assistant-Respuesta], HistFinal),
		assert_estado(UserID, buscar_tramite, _{historia:HistFinal}, [])
	  ;	Respuesta = "Perdón, ¿querés que lo ejecute o no?",
		assert_estado(UserID, elegir_modo_tramite, Contexto, [])
	  )
    ;	  resolver_intencion_modo(Hist1, D),
	  (	D.intent == "describir"
	  ->	T = Contexto.tramite,
		tramite_codigo_nombre_descripcion_motor(T,Nombre,Descripcion,DictMotor),
		format(string(Respuesta),
		       "Perfecto, ésta es la información para el trámite «~w»: ~n ~w ~n Instrucciones: ~w ~n ¿Querés que lo ejecute ahora?",[Nombre, Descripcion,DictMotor.'Descripcion']),
		append(Hist1, [assistant-Respuesta], HistFinal),
		assert_estado(UserID, elegir_modo_tramite,
			      Contexto.put(post_descripcion, true).put(historia, HistFinal), [])
	  ;	D.intent == "ejecutar"
	  ->	iniciar_ejecucion_tramite(UserID, Contexto, Respuesta)
	  ;	Respuesta = "Perdón, ¿querés una descripción del trámite o que lo ejecute?",
		assert_estado(UserID, elegir_modo_tramite, Contexto, [])
	  )
    ).

% ——————————————————————————————————————
% FASE 2.6 : CONFIRMAR CONTINUAR TRAMITE
% ——————————————————————————————————————

procesar_fase(UserID, confirmar_continuar_tramite, Line, Respuesta) :-
    retract_estado(UserID, confirmar_continuar_tramite, Contexto, P ),
    append(Contexto.historia, [user-Line], Hist1),
    resolver_intencion_pos_neg(Hist1, D),
    (	D.intent == "confirmar_si"
    ->
	T = Contexto.tramite,
	tramite_codigo_nombre_descripcion_motor(T,Nombre,_,_),
	%	informacion_tramite(T, Contexto.tramite, Asincronico,_Auth,_,_),
	ejecutar_tramite(UserID,Contexto,P,
			 "Perfecto, continuamos con el trámite «~w». ~s",
			 Nombre, Respuesta)
    ;   D.intent == "confirmar_no"
    ->  Respuesta = "De acuerdo, contame entonces qué trámite querés hacer.",
	append(Contexto.historia, [user-Line], NuevaHistNo),
	append(NuevaHistNo, [assistant-"De acuerdo, contame entonces qué trámite querés hacer."], HistFinal),
	assert_estado(UserID, buscar_tramite,
		      _{historia:HistFinal}, []),
	assert_tramite_pendiente(UserID, Contexto.tramiteid, Contexto, P)
    ;   Respuesta = "Perdón, ¿podés responder sí o no?",
	assert_estado(UserID, confirmar_continuar_tramite, Contexto, [])
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
    T = Contexto.tramite,
    tramite_codigo_nombre_descripcion_motor(T,_,_,DictMotor),
    %    informacion_tramite(T, Contexto.tramite, Asincronico,_Auth,_,_),
    Paso = paso(Id,_,_,Tipo,_),
    (   extraer_respuesta_por_tipo(Tipo, LineS, Line1)
    ->  assert_dato_tramite(UserID,DictMotor.codigochita,Contexto.tramiteid,Id,Line1),
	ejecutar_tramite(UserID,Contexto,Restantes,"~w~s",'',Respuesta)
    ;   % Respuesta inválida → repreguntar
	generar_repregunta_chatgpt(Contexto,Paso,Respuesta),
	assert_estado(UserID, ejecutar_tramite,
		      Contexto, [Paso|Restantes])
    ).


% ———————————————————————————————————————————————————————
% Predicados auxiliares de procesamiento de fases
% ———————————————————————————————————————————————————————

identificado(_,_) :- !. % deshabilidado por ahora
%identificado(0,_) :- !. % no requiere identificación
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
    atom_json_dict(String, Dict, [])
.
%    format(user_output,"respuesta de solicitud de identificacion original ~w~n",[Resp]).


iniciar_ejecucion_tramite(UserID, Contexto, Respuesta) :-
    T = Contexto.tramite,
    tramite_codigo_nombre_descripcion_motor(T,Nombre,_,DictMotor),
    uuid(TramiteID),
    ContextoNuevo = Contexto.put(topic,"tramitesPrueba")
	.put(tramiteid,TramiteID)
	.put(url,"66.70.179.213:9092")
	.put(topicomotor,"tramitesAsincronicos")
	.put(urlmotor,"66.70.179.213:9092")
	.put(instanciatramite,-1)
	.put(instanciastep,-1)
	.put(codigostep,-1)
	.put(accion,3),
    flujo_tramite_codigo_pasos(DictMotor.codigochita, P),
    %		  flujo_tramite(T, P ),
    (
	identificado(DictMotor.loginNecesario,UserID)
    ->
	ejecutar_tramite(UserID,
			 ContextoNuevo
			,P,"Perfecto, iniciemos el trámite «~w». ~s",Nombre, Respuesta)
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
	%		  assert_tramite_pendiente(UserID, TramiteID, Contexto.put(topic,"tramites").put(tramiteid,TramiteID).put(auth_required,true), P)
	assert_tramite_en_espera(UserID,T,TramiteID,
				 ContextoNuevo.put(auth_required,true))
    ).


ejecutar_tramite(UserID,Contexto,Pasos,Caption,Tram,Respuesta) :-
    ( Pasos = [Prox|_]
    ->  generar_pregunta_chatgpt(Contexto,Prox,Pregunta),
	format(string(Respuesta),Caption,[Tram, Pregunta]),
	assert_estado(UserID, ejecutar_tramite,Contexto,Pasos)
    ;
      tramite_completado(UserID,Contexto,Respuesta)
    ).

tramite_completado(UserID,Contexto,Respuesta) :-
    guardar_preguntas_cache,
    Tramite = Contexto.tramite,
    tramite_codigo_nombre_descripcion_motor(Tramite,_,_,DictMotor),
    T = DictMotor.codigochita,
    Asincronico = DictMotor.asincronico,
    TramiteID = Contexto.tramiteid,
    (   usuario_identificado(UserID,Token, _) -> true ; Token = "" ),
    ( Asincronico == true
    ->
      Respuesta = "Tu trámite se está procesando,  te avisaremos cuando esté listo.\n\n¿En qué otro trámite te puedo ayudar?"
    ;
      Respuesta = "Tramite en proceso\n"
    ),
    format(user_output,"antes de exportar ~w~n",[UserID]),
    exportar_datos_tramite_kafka(UserID,T,TramiteID,Token,Contexto),
    assert_tramite_en_espera(UserID,Tramite,TramiteID,Contexto).


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

normalizar_tramite_id(Dato,Codigo) :-
    atom(Dato),
    !,
    Codigo = Dato.

normalizar_tramite_id(Dato,Codigo) :-
    number(Dato),
    catch(atom_number(Codigo,Dato), _, fail).

normalizar_tramite_id(Dato,Codigo) :-
    string(Dato),
    catch(atom_string(Codigo,Dato), _, fail).

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
	    tramite_codigo_nombre_descripcion_motor(Contexto.tramite,T,_,DictMotor),
	    E = DictMotor.get(entidad, ""),
	    tramite_json:categoria_de_nombre(T, Cat)
	),
        L
    ),
    atom_json_dict(Pendientes, _{pendientes:L}, [as(string)]).

% El usuario escribió: «~s».

resolver_intencion_llm( Historia, Pendientes, Decision) :-
    tramites_disponibles(Tramites),
    format(string(Prompt),
	   "Eres un asistente para trámites administrativos argentinos.
Tu tarea es identificar qué trámite quiere realizar el usuario.

=== ESTRATEGIA DE ACOTAMIENTO ===
Seguí estos pasos en orden:

PASO 1 — Determinar continuar pendiente vs iniciar nuevo:
  Si hay trámites PENDIENTES y el usuario no aclara su intención,
  preguntale primero si quiere CONTINUAR uno pendiente o INICIAR algo nuevo.

PASO 2 — Acotar por MUNICIPIO/ENTIDAD:
  Si hay varios candidatos, revisá el campo \"entidad\" de cada trámite.
  Preguntale al usuario de qué municipio/entidad es el trámite
  (ej: \"¿El trámite es para el municipio de Escobar?\",
   \"¿Es para la Municipalidad o para Perico?\").

PASO 3 — Acotar por CATEGORÍA:
  Si sigue habiendo varios, preguntá por la categoría del trámite
  (ej: \"¿Buscás un certificado, una licencia, un permiso o una inscripción?\",
   \"¿Es un duplicado o una renovación?\").

PASO 4 — Confirmar por NOMBRE:
  Si quedan pocas opciones, preguntá directamente por el nombre.

=== LISTA DE TRÁMITES PENDIENTES (continuar): ===
~s

=== LISTA DE TRÁMITES DISPONIBLES (iniciar nuevo): ===
~s

=== REGLAS ===
- \"retomar_pendiente\": SOLO para trámites de la lista PENDIENTES. Indicá su \"tramite_id\" (uuid de la sesión pendiente).
- \"iniciar_nuevo\": SOLO para trámites de la lista DISPONIBLES. Indicá su \"codigo\" como \"tramite_nuevo\".
- \"preguntar\": cuando no puedas determinar con certeza. IMPORTANTE: la respuesta debe ser una pregunta ESPECÍFICA de acotamiento según los pasos 1-4 (no una pregunta genérica).
- Si la lista PENDIENTES está vacía, pasá directamente al paso 2 sin mencionarla.
- Si la lista DISPONIBLES está vacía, informá que no hay trámites disponibles.

Respondé ÚNICAMENTE en JSON (sin texto adicional):

{
  \"accion\": \"retomar_pendiente\" | \"iniciar_nuevo\" | \"preguntar\",
  \"tramite_id\": \"uuid\" | null,
  \"tramite_nuevo\": \"codigo\" | null,
  \"respuesta\": \"texto breve de la pregunta de acotamiento o confirmación\"
}

",
	   [Pendientes, Tramites]),
    H2 = [system-Prompt|Historia],
    (
	call_llm_with_context(H2, R1) ->
	normalizarjson(R1,R),
 	(
	    
	    is_json_valid(R) ->
	    
	    atom_json_dict(R, Decision, [])
	;	
	    Decision = _{accion:"preguntar",tramite_id:null, respuesta:R}
	
	)
    %% (
    %%     atom_json_dict(R, Decision, []) -> true
    %% ;
    %% Decision = _{accion:"continuar",tramite_id:null, respuesta:R}
    %% )
    ;
	Decision = _{accion:"error",tramite_id:null, respuesta:"Lo siento, no pude entender tu respuesta. ¿Podrías aclarar qué trámite te interesa?"}

    ).


normalizarjson(R,Resp) :-
    (
	sub_string(R,0,8,_,"```json\n") ->
	string_length(R,N),
	M is N - 12,
	sub_string(R,8,M,_,Resp)
    ;
	Resp = R
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
   → ej: \"sí\", \"si\", \"dale\", \"ok\", \"confirmo\", \"adelante\", \"correcto\", \"claro que sí\"
- confirmar_no  (rechazo claro)
   → ej: \"no\", \"para nada\", \"no gracias\", \"mejor no\", \"otro\", \"equivocado\"
- ambiguo       (no queda claro, responde con otra pregunta o duda)
   → ej: \"no sé\", \"tal vez\", \"depende\", \"cuéntame más\", \"y qué implica\", o una pregunta

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

resolver_intencion_modo(Historia,  Decision) :-
    format(string(Prompt),
	   "El usuario debe elegir entre recibir una descripción del trámite o ejecutarlo directamente.

Debes determinar si la intención es:
- describir  (quiere información/descripción del trámite)
   → ej: \"descripción\", \"contame más\", \"qué es\", \"explicame\", \"qué requisitos\", \"qué información\", \"cuéntame más\"
- ejecutar   (quiere iniciar la ejecución del trámite)
   → ej: \"ejecutá\", \"ejecutar\", \"iniciemos\", \"hagámoslo\", \"comencemos\", \"adelante\", \"dale, ejecutá\", \"sí, hacelo\"
- ambiguo    (no queda claro, responde con otra pregunta o duda)
   → ej: \"no sé\", \"tal vez\", \"depende\", o una pregunta

Respondé SOLO en JSON, sin texto adicional:

{
  \"intent\": \"describir\" | \"ejecutar\" | \"ambiguo\"
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

- continuar          → está respondiendo el dato pedido o dando información solicitada
   ej: \"mi cuit es 20-12345678-9\", \"sí, tengo turno\", \"es para la calle San Martín 123\"
- pausar_tramite     → quiere hacerlo después, más tarde, pausar, retomar luego
   ej: \"después\", \"más tarde\", \"lo dejo para luego\", \"pausa\", \"seguimos después\"
- cancelar_tramite   → no quiere seguir con el trámite, quiere cancelar
   ej: \"cancelar\", \"darse de baja\", \"no quiero seguir\", \"me arrepentí\", \"dejá así no más\"
- ambiguo            → no es clara la intención (pregunta, duda, saludo, etc.)

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



% ——————————————————————————————————————
% Generación de pregunta desde flujo
% ——————————————————————————————————————

generar_pregunta_chatgpt(Contexto,Paso,Pregunta) :-
    Tramite = Contexto.tramite,
    tramite_codigo_nombre_descripcion_motor(Tramite,Nombre,_,_),
    Paso = paso(Codigo,NombreCampo, Caption, Tipo, Opciones),
    (
	pregunta_cache(Tramite,Codigo, Pregunta) -> true
    ;
	(	Opciones \== [] -> format(string(Texto)," Por favor incluir en la pregunta estas opciones de respuesta ~w",[Opciones]) ; Texto = "" ),
	atomic_list_concat([
			       "Genera una pregunta clara y amable para pedir al usuario un dato dentro del trámite:",
			       Nombre, ".\n\n",
			       "Código del campo: ", Codigo, "\n",
			       "Nombre del campo: ", NombreCampo, "\n",
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

generar_repregunta_chatgpt(Contexto,Paso,Pregunta) :-
    Tramite = Contexto.tramite,
    tramite_codigo_nombre_descripcion_motor(Tramite,Nombre,_,_),
    Paso = paso(Codigo, NombreCampo,Caption, Tipo, Opciones),
    (	Opciones \== [] -> format(string(Texto)," Por favor incluir en la pregunta estas opciones de respuesta ~w, opcion(X,Y) significa si el usuario selecciona Y responder X",[Opciones]) ; Texto = "" ),
    atomic_list_concat([
			   "Por favor reformular una pregunta clara y amable para pedir al usuario un dato dentro del trámite:",
			   Nombre, ".\n\n",
			   "Código del campo: ", Codigo, "\n",
			   "Nombre del campo: ", NombreCampo, "\n",
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

