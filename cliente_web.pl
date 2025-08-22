:- module(cliente_web, [start_webchat_server/1
		       ]).


:- use_module(library(http/thread_httpd)).
:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_parameters)).
:- use_module(library(http/html_write)).
:- use_module(library(http/http_client)).
:- use_module(library(lists), [append/3, member/2]).
:- use_module(library(http/json)).
%:- use_module(library(http/json_convert)).

:- dynamic historial_web/2.

:- http_handler(root(webchat), webchat_handler, []).

start_webchat_server(Port) :-
    http_server(http_dispatch, [port(Port)]).

webchat_handler(Request) :-
    http_parameters(Request, [
        user_id(UserID, [optional(true), default(user)]),
        mensaje(Mensaje, [optional(true), default('')])
    ]),
    actualizar_historial(UserID, Mensaje, Respuesta),
    mostrar_conversacion(UserID, Mensaje, Respuesta, HTML),
    reply_html_page(
        title('Chatbot Web'),
        HTML
    ).

actualizar_historial(_, '', _) :- !.  % No enviar vacío

actualizar_historial(UserID, Mensaje, Respuesta) :-
    % Enviar el mensaje al chatbot
    chat_request(UserID, Mensaje, Respuesta),
    % Guardar en historial (usuario + bot)
    (   retract(historial_web(UserID, H0)) -> true ; H0 = []),
    append(H0, [user-Mensaje, bot-Respuesta], H1),
    assertz(historial_web(UserID, H1)).

mostrar_conversacion(UserID, _, _, HTML) :-
    (   historial_web(UserID, Mensajes) -> true ; Mensajes = []),
    findall(
        P,
        ( member(Role-Text, Mensajes),
          etiqueta(Role, E),
          P = p([b(E), ': ', Text])
        ),
        Conversacion
    ),
    format(string(Titulo),"Chatbot Web --- ~s",[UserID]),
    HTML = [
        h1(Titulo),
        \html_conversacion(Conversacion),
        form([method(get), action('/webchat')], [
            input([type(hidden), name(user_id), value(UserID)]),
            input([type(text), name(mensaje), placeholder('Escribe tu mensaje...')]),
            input([type(submit), value('Enviar')])
        ])
    ].

etiqueta(user, 'Usuario').
etiqueta(bot, 'Chita').

html_conversacion([]) --> [].
html_conversacion([L|Ls]) --> html(L), html_conversacion(Ls).

% Enviar mensaje al chatbot local
chat_request(UserID, Texto, Respuesta) :-
    URL = 'http://localhost:8000/chat',
    dict_create(Msg, message, _{ user_id: UserID, text: Texto }),
    JSONDict = _{ message: Msg },
    atom_json_dict(Atom, JSONDict, []),
    format(user_output,"envia ~s~n",[Texto]),
    http_post(URL, string(Atom), JSONReply, [request_header('Content-Type'='application/json')]),
    atom_json_dict(JSONReply,Reply, []),
    Respuesta = Reply.respuesta.



% http://localhost:8080/webchat?user_id=usuario1
