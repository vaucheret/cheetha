:- module(chatbot, [start_server/1, iniciar_chat/0]).

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


:- dynamic pregunta_cache/3.
:- dynamic historia/2.
:- dynamic estado/4.

openai_api_key(Key) :-
      getenv('OPENAI_API_KEY', Key),
      !.


start_server(Port) :-
    cargar_tramites,
    cargar_preguntas_cache,
    inicio(H),
    assertz(historia(anonimo,H)),
    http_server(http_dispatch, [port(Port), workers(4)]).


iniciar_chat :-
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
% DIALOGO
% ——————————————————————————————————————

dialogo(UserID,Line, Respuesta) :-
    retract(historia(UserID,Hist0)),
    (
	string_codes(Line,LineS),
	phrase((..., terminar, ...), LineS) ->
        Respuesta = "¡Hasta luego! Gracias por consultar",
        inicio(H0),
	assertz(historia(UserID,H0))
    ;
    (
	intencion(Line, iniciar_tramite(T)),
	flujo_tramite(T,[Paso|Pasos]) ->
        generar_pregunta_chatgpt(T,Paso,Respuesta),
        assertz(estado(UserID,[user-Line|Hist0],T,[Paso|Pasos]))
    ;
    (
	append(Hist0,[user-Line], H1),
	call_chatgpt_with_context(H1, Respuesta),
	atom_string(Respuesta,RespuestaS),
	append(H1,[assistant-RespuestaS],H2),
	assertz(historia(UserID,H2))
    )
    )
    ).


dialogo(UserID,Line, Respuesta) :-
    retract(estado(UserID,Hist0, Tramite, [Paso|R])),
    (
	string_codes(Line,LineS),
	phrase((..., terminar, ...), LineS) ->
        Respuesta = "Trámite cancelado.",
	inicio(HN),
	assertz(historia(UserID,HN))
    ;
    (
	Paso = paso(Id,_,Tipo,_),
	extraer_respuesta_por_tipo(Tipo,Line,Line1),
	assertz(dato_tramite(UserID,Tramite,Id,Line1)),
	(
	    R = [Next|_] ->
            generar_pregunta_chatgpt(Tramite,Next,Respuesta),
          assertz(estado(UserID,[user-Line|Hist0],Tramite,R))
	;
	(
            guardar_preguntas_cache,

%	    atom_concat('tramite_', Tramite, NombreBase),
%	    atom_concat(NombreBase, '.json', Archivo),
%	    format(string(Intro),"Hemos terminado el flujo para ~a.  Pronto verás los resultados o próximos pasos.\n Aquí los datos:\n",[Tramite]),
%	    findall(L, (dato_tramite(UserID,Tramite,I,V), format(string(L),"- ~a: ~s\n",[I,V])), Ls),
%	    atomic_list_concat(Ls, Body),
%	    format(string(Respuesta), "~s~a Datos del trámite guardados en: ~w\n En que otro tramite te puedo ayudar?", [Intro,Body,Archivo]),
%	    exportar_datos_tramite(UserID,Tramite, Archivo),


	    exportar_datos_tramite_kafka(UserID,Tramite),

	    esperar_respuesta_kafka(UserID,Tramite, MensajeKafka),

 	    format(string(Respuesta), "~s\n\n¿En qué otro trámite te puedo ayudar?", [MensajeKafka]),
	    inicio(HistN),
	    assertz(historia(UserID,HistN))
	)
	)
      )
    ).

dialogo(UserID,Line, Respuesta) :-
    historia(anonimo,Hist0),
    assertz(historia(UserID,Hist0)),
    dialogo(UserID,Line, Respuesta).




% ——————————————————————————————————————
% ChatGPT API integration
% ——————————————————————————————————————

call_chatgpt_with_context(HistMsgs, Response) :-
    openai_api_key(Key),
    build_json_dict(HistMsgs, JSONDICT),
    http_post('https://api.openai.com/v1/chat/completions',
              json(JSONDICT),
              ReplyDict,
              [
		  authorization(bearer(Key)),
		  application/json
	      ]),
    extract_gpt_response(ReplyDict, Response).

build_json_dict(Msgs, _{
    model: "gpt-3.5-turbo",
    messages: MessagesList
}) :-
    maplist(to_message_obj, Msgs, MessagesList).

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
            call_chatgpt_with_context([user-Prompt], Pregunta),
	    assertz(pregunta_cache(Tramite,Codigo,Pregunta))
        ),
        _Error,
        (
            Pregunta = Caption
        )
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
