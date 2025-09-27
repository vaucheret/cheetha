:- module(chatbot, [start_server/2, iniciar_chat/1]).

:- use_module(library(http/thread_httpd)).
:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_json)).
:- use_module(library(http/http_client)).
:- use_module(library(lists)).
:- use_module(tramite_json).
:- use_module(gramatica).
:- use_module(library(apply), [maplist/3]).
:- use_module(library(listing), [portray_clause/2]).
:- use_module(library(readutil), [read_line_to_string/2]).
:- use_module(library(uuid),[uuid/1]).

:- dynamic current_provider/1.

:- dynamic pregunta_cache/3.
:- dynamic historia/2.
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
    cargar_tramites,
    cargar_preguntas_cache,
    inicio(H),
    assertz(historia(anonimo,H)),
    http_server(http_dispatch, [port(Port), workers(4)]).


iniciar_chat(Provider) :-
    set_provider(Provider),
    cargar_tramites,
    cargar_preguntas_cache,
    inicio(H),
    assertz(historia(_,H)),
    chat_loop.

inicio([system-Prompt]) :-
    tramites_disponibles(L),
    atomic_list_concat(L, ", ", S),
    format(string(Prompt),"Eres un asistente para trámites: ~s", [S]).

tramites_disponibles(L) :- findall(T, tramite_disponible(T), L).

% ——————————————————————————————————————
% LOOP
% ——————————————————————————————————————


:- http_handler(root(chat), handle_chat, [method(post)]).

handle_chat(Request) :-
    http_read_json_dict(Request, In),
    UserID = In.message.user_id,
    Text = In.message.text,
    string_lower(Text,TextLower),
%    format(user_output,"pregunta ~s~n",[TextLower]),	      		      
    dialogo(UserID,TextLower, Respuesta),
    format(string(RS), "~w", [Respuesta]),
%    format(user_output,"responde ~s~n",[RS]),	      
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
% DIALOGO
% ——————————————————————————————————————

dialogo(UserID,Line, Respuesta) :-
    retract(historia(UserID,Hist0)),
    string_codes(Line,LineS),
%    format(user_output,"retract historia ~w con ~w preg: ~s ~n",[UserID,Hist0,Line]),	      		      
    (
	phrase((..., terminar, ...), LineS) ->
        Respuesta = "¡Hasta luego! Gracias por consultar",
        inicio(H0),
	assertz(historia(UserID,H0))
%	format(user_output,"aserta historia inicial ~w con ~w ~n",[UserID,H0])	      		      
    ;
    (
	intencion(LineS, iniciar_tramite(T)),
	flujo_tramite(T,[Paso|Pasos]) ->
        generar_pregunta_chatgpt(T,Paso,Respuesta),
        assertz(estado(UserID,[user-Line|Hist0],T,[Paso|Pasos]))
%	format(user_output,"aserta estado para ~w con ~w , y ~w y ~w  ~n",[UserID,[user-Line|Hist0],T,[Paso|Pasos]])	      		      	
    ;
    (
	append(Hist0,[user-Line], H1),
	call_llm_with_context(H1, Respuesta),
	atom_string(Respuesta,RespuestaS),
	append(H1,[assistant-RespuestaS],H2),
	assertz(historia(UserID,H2))
%	format(user_output,"aserta historia  ~w con ~w  ~n",[UserID,H2])	      		      
    )
    )
    ).


dialogo(UserID,Line, Respuesta) :-
    retract(estado(UserID,Hist0, Tramite, [Paso|R])),
    string_codes(Line,LineS),
%    format(user_output,"retract estado ~w con ~w , y ~w y ~w  ~n",[UserID,Hist0,Tramite,[Paso|R]]),
    (
	phrase((..., terminar, ...), LineS) ->
        Respuesta = "Trámite cancelado.",
	inicio(HN),
	assertz(historia(UserID,HN))
%	format(user_output,"aserta historia ~w con ~w  ~n",[UserID,HN])
    ;
    (
	Paso = paso(Id,_,Tipo,_),
	(   
	    extraer_respuesta_por_tipo(Tipo,LineS,Line1) ->
	    assertz(dato_tramite(UserID,Tramite,Id,Line1)),
	    (
		R = [Next|_] ->
		generar_pregunta_chatgpt(Tramite,Next,Respuesta),
		assertz(estado(UserID,[user-Line|Hist0],Tramite,R))
%	        format(user_output,"assert estado ~w con ~w , y ~w y ~w  ~n",[UserID,[user-Line|Hist0],Tramite,R])
	    ;
	    (
		guardar_preguntas_cache,

			    %% atom_concat('tramite_', Tramite, NombreBase),
			    %% atom_concat(NombreBase, '.json', Archivo),
			    %% format(string(Intro),"Hemos terminado el flujo para ~a.  Pronto verás los resultados o próximos pasos.\n Aquí los datos:\n",[Tramite]),
			    %% findall(L, (dato_tramite(UserID,Tramite,I,V), format(string(L),"- ~a: ~s\n",[I,V])), Ls),
			    %% atomic_list_concat(Ls, Body),
			    %% format(string(Respuesta), "~s~a Datos del trámite guardados en: ~w\n En que otro tramite te puedo ayudar?", [Intro,Body,Archivo]),
			    %% exportar_datos_tramite(UserID,Tramite,TramiteID,Archivo),

                uuid(TramiteID),
		exportar_datos_tramite_kafka(UserID,Tramite,TramiteID),

		esperar_respuesta_kafka(UserID,Tramite,TramiteID, MensajeKafka),

 		format(string(Respuesta), "~s\n\n¿En qué otro trámite te puedo ayudar?", [MensajeKafka]),
		
		inicio(HistN),
		assertz(historia(UserID,HistN))
%		format(user_output,"aserta historia despues de kafka ~w con ~w  ~n",[UserID,HistN])
	    )
	    )
	;
	% repreguntar
	    generar_repregunta_chatgpt(Tramite,Paso,Respuesta),
	    assertz(estado(UserID,[user-Line|Hist0],Tramite,[Paso|R]))
%            format(user_output,"aserta estado ~w con ~w , y ~w y ~w  ~n",[UserID,[user-Line|Hist0],Tramite,[Paso|R]])	   
	)
	)
    ).

dialogo(UserID,Line, Respuesta) :-
    historia(anonimo,Hist0),
    assertz(historia(UserID,Hist0)),
%    format(user_output,"aserta historia last ~w con ~w  ~n",[UserID,Hist0]),
%    format(user_output,"pregunta last ~s~n",[Line]),	      		      
    dialogo(UserID,Line, Respuesta).




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
    findall(historia(U, H), historia(U, H), Hs),
    findall(estado(U, H0, T, R), estado(U, H0, T, R), Es),
    findall(dato_tramite(U, T, I, V), dato_tramite(U, T, I, V), Ds),
    append([Hs, Es, Ds], Todos),
    portray_clauses(Todos, S).

cargar_estado_usuarios :-
    ( exists_file('estado_usuarios.pl') -> consult('estado_usuarios.pl') ; true ).
