test :-
    UserID = "repro-directo-1",
    format(user_output,"a: estado?~n",[]),
    (   chatbot:estado(UserID, FaseFinal, CtxFinal, _)
    ->  format(user_output,"   existe: fase=~w~n",[FaseFinal])
    ;   FaseFinal = buscar_tramite,
	CtxFinal = _{historia:[], canal:a2a, task_id_a2a:"t-r"},
	format(user_output,"   NO existe, fallback ~w~n",[FaseFinal])
    ),
    format(user_output,"b: estado_a2a...~n",[]),
    (   chatbot:estado_a2a(FaseFinal, CtxFinal, EstadoA2A, Artifact)
    ->  format(user_output,"   OK: ~w / artifact=~w~n",[EstadoA2A,Artifact])
    ;   format(user_output,"   *** estado_a2a FALLO ***~n",[])
    ),
    format(user_output,"c: tramite_en_espera + deep_link...~n",[]),
    (   chatbot:tramite_en_espera(UserID,_,_,CtxEspera)
    ->  format(user_output,"   tramite_en_espera OK: ~w~n",[CtxEspera]),
	(   get_dict(deep_link_verificacion, CtxEspera, DeepLink)
	->  format(user_output,"   deep_link: ~s~n",[DeepLink])
	;   format(user_output,"   *** SIN deep_link_verificacion ***~n",[])
	)
    ;   format(user_output,"   *** SIN tramite_en_espera ***~n",[])
    ).
