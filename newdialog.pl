
% ——————————————————————————————————————
% NUEVO DIALOGO con dos fases
% ——————————————————————————————————————

dialogo(UserID, Line, Respuesta) :-
    string_codes(Line, LineS),
    % Cancelar diálogo globalmente
    (   phrase((..., terminar, ...), LineS)
    ->  Respuesta = "Gracias por usar el asistente. ¡Hasta luego!",
        inicio(H0),
        retractall(historia(UserID,_)),
        retractall(estado(UserID,_,_,_)),
        assertz(historia(UserID,H0)), !
    ;   true),

    % Recuperar o inicializar estado
    (   estado(UserID, Fase, Contexto, _)
    ->  true
    ;   Fase = buscar_tramite,
        Contexto = _{historia: [], intento: 0},
        assertz(estado(UserID, Fase, Contexto, []))
    ),

    procesar_fase(UserID, Fase, Line, Respuesta).

% ——————————————————————————————————————
% FASE 1: BUSCAR TRAMITE
% ——————————————————————————————————————

procesar_fase(UserID, buscar_tramite, Line, Respuesta) :-
    retract(estado(UserID, _, Contexto, _)),
    detectar_tramite_llm(Line, Tramite, Pregunta),
    (   nonvar(Tramite),
        Tramite \== null,
        tramite_disponible(Tramite)
    ->  format(string(Respuesta),
               "~s ¿Querés hacer el trámite «~w»?", [Pregunta, Tramite]),
        assertz(estado(UserID, confirmar_tramite,
                       _{tramite: Tramite, historia:[user-Line]}, []))
    ;   % No detectó trámite → seguir preguntando
        format(string(Respuesta), "~s", [Pregunta]),
        append(Contexto.historia, [user-Line], NuevaHist),
        assertz(estado(UserID, buscar_tramite,
                       _{historia:NuevaHist, intento: Contexto.intento+1}, []))
    ).

% ——————————————————————————————————————
% FASE 2: CONFIRMAR TRAMITE
% ——————————————————————————————————————

procesar_fase(UserID, confirmar_tramite, Line, Respuesta) :-
    retract(estado(UserID, _, Contexto, _)),
    string_lower(Line, Lower),
    (   sub_string(Lower, _, _, _, "si")
    ->  T = Contexto.tramite,
        flujo_tramite(T, [Paso|Pasos]),
        generar_pregunta_chatgpt(T, Paso, Pregunta),
        format(string(Respuesta),
               "Perfecto, iniciemos el trámite «~w». ~s", [T, Pregunta]),
        assertz(estado(UserID, ejecutar_tramite,
                       _{tramite:T, historia:[user-Line]}, [Paso|Pasos]))
    ;   sub_string(Lower, _, _, _, "no")
    ->  Respuesta = "De acuerdo, contame entonces qué trámite querés hacer.",
        assertz(estado(UserID, buscar_tramite,
                       _{historia:[], intento:0}, []))
    ;   Respuesta = "Perdón, ¿podés responder sí o no?",
        assertz(estado(UserID, confirmar_tramite, Contexto, []))
    ).

% ——————————————————————————————————————
% FASE 3: EJECUTAR TRAMITE (flujo de pasos)
% ——————————————————————————————————————

procesar_fase(UserID, ejecutar_tramite, Line, Respuesta) :-
    retract(estado(UserID, _, Contexto, [Paso|Restantes])),
    T = Contexto.tramite,
    string_codes(Line, LineS),
    (   phrase((..., terminar, ...), LineS)
    ->  Respuesta = "Trámite cancelado. Volvamos a empezar.",
        inicio(HN),
        assertz(historia(UserID,HN))
    ;   Paso = paso(Id,_,Tipo,_),
        (   extraer_respuesta_por_tipo(Tipo, LineS, Line1)
        ->  assertz(dato_tramite(UserID,T,Id,Line1)),
            (   Restantes = [Prox|RestoPasos]
            ->  generar_pregunta_chatgpt(T,Prox,Respuesta),
                assertz(estado(UserID, ejecutar_tramite,
                               _{tramite:T}, [Prox|RestoPasos]))
            ;   uuid(TramiteID),
                exportar_datos_tramite_kafka(UserID,T,TramiteID),
                esperar_respuesta_kafka(UserID,T,TramiteID,MensajeKafka),
                format(string(Respuesta),
                       "~s\n\n¿En qué otro trámite te puedo ayudar?",
                       [MensajeKafka]),
                inicio(HistN),
                assertz(historia(UserID,HistN))
            )
        ;   % Respuesta inválida → repreguntar
            generar_repregunta_chatgpt(T,Paso,Respuesta),
            assertz(estado(UserID, ejecutar_tramite,
                           _{tramite:T}, [Paso|Restantes]))
        )
    ).

% ——————————————————————————————————————
% FALLBACK: Si no hay estado aún
% ——————————————————————————————————————

dialogo(UserID, Line, Respuesta) :-
    historia(anonimo,H0),
    assertz(historia(UserID,H0)),
    dialogo(UserID, Line, Respuesta).

% ——————————————————————————————————————
% Detección flexible de trámite por LLM
% ——————————————————————————————————————

detectar_tramite_llm(Utterance, Tramite, Pregunta) :-
    tramites_disponibles(L),
    atomic_list_concat(L, ', ', ListaTramites),
    format(string(Prompt),
"El usuario escribió: «~s».
Debes identificar cuál de estos trámites quiere realizar (lista: ~s).
Responde SOLO en JSON, por ejemplo:
{ \"tramite_detectado\": \"nombre_tramite\" o null,
  \"pregunta\": \"texto breve para confirmar o preguntar\" }.",
           [Utterance, ListaTramites]),
    call_llm_with_context([user-Prompt], R),
    catch(atom_json_dict(R, D, []),
          _, D = _{tramite_detectado:null, pregunta:"¿Podrías aclarar qué trámite te interesa?"}),
    Tramite = D.get(tramite_detectado),
    Pregunta = D.get(pregunta).

