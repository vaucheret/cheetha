:- module(persistencia, [
    init_db/0,

    % estado activo (una sola sesión activa por usuario) estado(user_id, fase, contexto, pasos)
    estado/4,
    assert_estado/4,
    retract_estado/4,
    retractall_estado/4,

    % trámites pausados / pendientes tramite_pendiente(user_id, tramite_id, contexto, pasos contexto(tramite)
    tramite_pendiente/4,
    assert_tramite_pendiente/4,
    retract_tramite_pendiente/4,
    retractall_tramite_pendiente/4,

    % tramite_en_espera(user_id, tramite, tramite_id, contexto) contexto(tramite,topic,tramiteid,auth_required)
    tramite_en_espera/4, 
    assert_tramite_en_espera/4,
    retract_tramite_en_espera/4,
    retractall_tramite_en_espera/4,

    dato_tramite/5,
    assert_dato_tramite/5,
    retract_dato_tramite/5,
    retractall_dato_tramite/5,

    usuario_identificado/3,
    assert_usuario_identificado/3,
    retract_usuario_identificado/3
    
]).

:- use_module(library(persistency)).


% --------------------------------------------------
% PERSISTENT FACTS
% --------------------------------------------------

:- persistent
    estado(
        user_id:string,
        fase:atom,
        contexto:dict,
        pasos:list
    ),

    tramite_pendiente(
        user_id:string,
        tramite_id:atom, 
        contexto:dict,
	pasos:list
    ),

    tramite_en_espera(
        user_id:string,
	tramite:integer, % (deberia ser el codigo)
        tramite_id:atom,
        contexto:dict
    ),

    dato_tramite(
	user_id:string,
	tramite:integer, % (deberia ser el codigo)
	tramite_id: atom,
	clave:atom,
	valor:string
    ),

    usuario_identificado(
	user_id:string,
	token:string,
	fecha_expiracion:string
    ).

% --------------------------------------------------
% INIT
% --------------------------------------------------

init_db :-
    db_attach('chatbot.db', []),
    db_sync(gc).


