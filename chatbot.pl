:- module(chatbot, [start_server/2, iniciar_chat/1]).

:- use_module(library(http/thread_httpd)).
:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_json)).
:- use_module(library(http/http_client)).
:- use_module(library(lists)).
:- use_module(tramite_json).
:- use_module(gramatica).
:- use_module(library(http/json)).
:- use_module(library(apply), [maplist/3]).
:- use_module(library(listing), [portray_clause/2]).
:- use_module(library(readutil), [read_line_to_string/2]).
:- use_module(library(uuid),[uuid/1]).

:- dynamic current_provider/1.

:- dynamic pregunta_cache/3.
:- dynamic estado/4.

openai_api_key(Key) :-
      getenv('OPENAI_API_KEY', Key),
      !.

deepseek_api_key(Key) :-
    %			getenv('DEEPSEEK_API_KEY', Key),
    			getenv('OPENROUTER_API_KEY', Key),
			!.

gemini_api_key(Key) :-
    %			getenv('GEMINI_API_KEY', Key),
    			getenv('OPENROUTER_API_KEY', Key),
			!.




set_provider(Provider) :-   % openai o deepseek
    retractall(current_provider(_)),
    assertz(current_provider(Provider)).


start_server(Provider,Port) :-
    set_provider(Provider),
%    cargar_tramites,
    cargar_tramites_from_url2,
    cargar_preguntas_cache,
    cargar_estado_usuarios,
    http_server(http_dispatch, [port(Port), workers(4)]).


iniciar_chat(Provider) :-
    set_provider(Provider),
%    cargar_tramites,
    cargar_tramites_from_url2,
    cargar_preguntas_cache,
    cargar_estado_usuarios,
    chat_loop.

%% inicio([system-Prompt]) :-
%%     tramites_disponibles(L),
%%     atomic_list_concat(L, ", ", S),
%%     format(string(Prompt),"Eres un asistente para trámites: ~s", [S]).



% ——————————————————————————————————————
% LOOP
% ——————————————————————————————————————


:- http_handler(root(chat), handle_chat, [method(post)]).

handle_chat(Request) :-
    http_read_json_dict(Request, In),
    UserID = In.message.user_id,
    Text = In.message.text,
    string_lower(Text,TextLower),
    format(user_output,"pregunta ~s~n",[TextLower]),	      		      
    dialogo(UserID,TextLower, Respuesta),
    format(string(RS), "~w", [Respuesta]),
    format(user_output,"responde ~s~n",[RS]),	      
    set_stream(user_output, encoding(utf8)),
    reply_json_dict(_{ respuesta:RS }, [encoding(utf8)]).

chat_loop :-
    prompt(you),
    read_line_to_string(user_input, Line),
    string_lower(Line,TextLower),					      
    dialogo(toplevel,TextLower, R),
    prompt(me),
    writeln(R),
    chat_loop.



% ——————————————————————————————————————
% NUEVO DIALOGO con dos fases
% ——————————————————————————————————————

dialogo(UserID, Line, Respuesta) :-
    estado(UserID, Fase, _, _),
    string_codes(Line, LineS),
    % Cancelar diálogo globalmente
    (   phrase((..., terminar, ...), LineS)
    ->  Respuesta = "Gracias por usar el asistente. ¡Hasta luego!",
        retractall(estado(UserID,_,_,_))
    ;  
    
    procesar_fase(UserID, Fase, Line, Respuesta)
    ),
    guardar_estado_usuarios.


% ——————————————————————————————————————
% FALLBACK: Si no hay estado aún
% ——————————————————————————————————————

dialogo(UserID, Line, Respuesta) :-
    	% Recuperar o inicializar estado
        Fase = buscar_tramite,
        Contexto = _{historia: [system-"Eres un asistente para trámites"]},
        assertz(estado(UserID, Fase, Contexto, [])),
	dialogo(UserID, Line, Respuesta).


% ——————————————————————————————————————
% FASE 1: BUSCAR TRAMITE
% ——————————————————————————————————————

procesar_fase(UserID, buscar_tramite, Line, Respuesta) :-
    retract(estado(UserID, _, Contexto, _)),
    append(Contexto.historia, [user-Line], NuevaHist),
    detectar_tramite_llm(Line,NuevaHist, Tramite, Pregunta),
    append(NuevaHist, [assistant-Pregunta], HistConPregunta),
    (   nonvar(Tramite),
        Tramite \== null,
	codigo_interno(TramiteA,Tramite),
        tramite_disponible(TramiteA)
    ->  format(string(Respuesta),
               "~s ¿Querés hacer el trámite «~w»?", [Pregunta, TramiteA]),
        assertz(estado(UserID, confirmar_tramite,
                       _{tramite: Tramite, historia:HistConPregunta}, []))
    ;   % No detectó trámite → seguir preguntando
        format(string(Respuesta), "~s", [Pregunta]),
        assertz(estado(UserID, buscar_tramite,
                       _{historia:HistConPregunta}, []))
    ).

% ——————————————————————————————————————
% FASE 2: CONFIRMAR TRAMITE
% ——————————————————————————————————————

procesar_fase(UserID, confirmar_tramite, Line, Respuesta) :-
    retract(estado(UserID, _, Contexto, _)),
    string_lower(Line, Lower),
    (	(   sub_string(Lower, _, _, _, "si");sub_string(Lower, _, _, _, "sí"))
    ->
        codigo_interno(T, Contexto.tramite),
        flujo_tramite(T, [Paso|Pasos]),
        generar_pregunta_chatgpt(T, Paso, Pregunta),
        format(string(Respuesta),
               "Perfecto, iniciemos el trámite «~w». ~s", [T, Pregunta]),
        assertz(estado(UserID, ejecutar_tramite,
                       Contexto, [Paso|Pasos]))
    ;   sub_string(Lower, _, _, _, "no")
	->  Respuesta = "De acuerdo, contame entonces qué trámite querés hacer.",
	    append(Contexto.historia, [user-Line], NuevaHistNo),
	    append(NuevaHistNo, [assistant-"De acuerdo, contame entonces qué trámite querés hacer."], HistFinal),
        assertz(estado(UserID, buscar_tramite,
                       _{historia:HistFinal}, []))
    ;   Respuesta = "Perdón, ¿podés responder sí o no?",
        assertz(estado(UserID, confirmar_tramite, Contexto, []))
    ).

% ——————————————————————————————————————
% FASE 3: EJECUTAR TRAMITE (flujo de pasos)
% ——————————————————————————————————————

procesar_fase(UserID, ejecutar_tramite, Line, Respuesta) :-
    retract(estado(UserID, _, Contexto, [Paso|Restantes])),
    string_codes(Line,LineS),
    codigo_interno(T, Contexto.tramite),
    Paso = paso(Id,_,Tipo,_),
        (   extraer_respuesta_por_tipo(Tipo, LineS, Line1)
        ->  assertz(dato_tramite(UserID,T,Id,Line1)),
            (   Restantes = [Prox|_]
            ->  generar_pregunta_chatgpt(T,Prox,Respuesta),
                assertz(estado(UserID, ejecutar_tramite,
                               Contexto, Restantes))
            ;
	        guardar_preguntas_cache,
	        uuid(TramiteID),
                exportar_datos_tramite_kafka(UserID,T,TramiteID),
                esperar_respuesta_kafka(UserID,T,TramiteID,MensajeKafka),
                format(string(Respuesta),
                       "~s\n\n¿En qué otro trámite te puedo ayudar?",
                       [MensajeKafka])
            )
        ;   % Respuesta inválida → repreguntar
            generar_repregunta_chatgpt(T,Paso,Respuesta),
            assertz(estado(UserID, ejecutar_tramite,
                           Contexto, [Paso|Restantes]))
    
    ).


% ——————————————————————————————————————
% Detección flexible de trámite por LLM
% ——————————————————————————————————————

detectar_tramite_llm(Utterance, Historia, Tramite, Pregunta) :-
    tramites_disponibles(ListaTramites),
    format(string(Prompt),
"El usuario escribió: «~s».
Debes identificar cuál de estos trámites quiere realizar (lista de tramites con codigo,nombre y descripcion: ~s).
Responde SOLO en JSON, por ejemplo:
{ \"tramite_detectado\": \"codigo\" o null,
  \"pregunta\": \"texto breve para confirmar si el tramite fue detectado o si es null nueva pregunta para indagar al usuario cual es el tramite a realizar\" }.",
[Utterance, ListaTramites]),
    append(Historia, [user-Prompt], NewHistory),
    call_llm_with_context(NewHistory, R),
    catch(atom_json_dict(R, D, []),
          _, D = _{tramite_detectado:null, pregunta:"¿Podrías aclarar qué trámite te interesa?"}),
    Tramite = D.get(tramite_detectado),
    Pregunta = D.get(pregunta).




% ——————————————————————————————————————
% ChatGPT API integration
% ——————————————————————————————————————

call_llm_with_context(HistMsgs, Response) :-
    current_provider(openai), !,
    openai_call(HistMsgs, Response).

call_llm_with_context(HistMsgs, Response) :-
    current_provider(deepseek), !,
    deepseek_call(HistMsgs, Response).


call_llm_with_context(HistMsgs, Response) :-
    current_provider(gemini), !,
    gemini_call(HistMsgs, Response).


openai_call(HistMsgs, Response) :-
    openai_api_key(Key),
    build_json_dict(HistMsgs, openai, JSONDICT),
    http_post('https://api.openai.com/v1/chat/completions',
              json(JSONDICT),
              ReplyDict,
              [
                  authorization(bearer(Key)),
                  application/json
              ]),
    extract_gpt_response(ReplyDict, Response).


deepseek_call(HistMsgs, Response) :-
    deepseek_api_key(Key),
    build_json_dict(HistMsgs,deepseek, JSONDICT),
%    http_post('https://api.deepseek.com/chat/completions',
    http_post('https://openrouter.ai/api/v1/chat/completions',	      
              json(JSONDICT),
              ReplyDict,
              [
                  authorization(bearer(Key)),
                  application/json
              ]),
    extract_gpt_response(ReplyDict, Response).

gemini_call(HistMsgs, Response) :-
    gemini_api_key(Key),
    build_json_dict(HistMsgs,gemini, JSONDICT),
%    http_post('https://api.deepseek.com/chat/completions',
    http_post('https://openrouter.ai/api/v1/chat/completions',	      
              json(JSONDICT),
              ReplyDict,
              [
                  authorization(bearer(Key)),
                  application/json
              ]),
    extract_gpt_response(ReplyDict, Response).



build_json_dict(Msgs,Provider, _{
    model: Model, 
    messages: MessagesList
}) :-
    maplist(to_message_obj, Msgs, MessagesList), 
    (
	Provider = openai -> Model = "gpt-3.5-turbo"
    ;
%      Provider = deepseek -> Model = "deepseek-chat"
        Provider = deepseek -> Model = "deepseek/deepseek-chat-v3.1:free"
    ;	
        Provider = gemini -> Model = "google/gemini-2.0-flash-exp:free"
    ).

to_message_obj(Role-Text, _{role:SRole, content:Text}) :-
    atom_string(Role, SRole).


extract_gpt_response(json(L), Content) :-
    member(choices=[json(Choices)],L),
    member(message=json(Message),Choices),
    member(content=Content,Message).


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


guardar_estado_usuarios :-
    open('estado_usuarios.pl', write, S),
    findall(estado(U, H0, T, R), estado(U, H0, T, R), Es),
    findall(dato_tramite(U, T, I, V), dato_tramite(U, T, I, V), Ds),
    append([Es, Ds], Todos),
    portray_clauses(Todos, S).

cargar_estado_usuarios :-
    ( exists_file('estado_usuarios.pl') -> consult('estado_usuarios.pl') ; true ).
