:- module(nlu, [
			    modo_nlu/1,
			    preguntas_llm_habilitadas/0,
			    acto_dialogo/2,
			    catalogo_actual/1,
			    candidatos_tramite/2,
			    candidatos_en_catalogo/3,
			    shortlist_tramites/3,
			    resolver_candidato_previo/3,
			    lista_candidatos_json/2,
			    capitalizar/2
			]).

:- use_module(library(apply), [maplist/3, include/3]).
:- use_module(library(lists), [memberchk/2, nth1/3, append/3, delete/3,
			       reverse/2, last/2]).
:- use_module(library(json)).
:- use_module(gramatica, [normalizar_texto/2,
			  tokens/2,
			  es_despedida/1,
			  si_no/2,
			  control_tramite/2,
			  es_ambiguo_explicito/1]).
:- use_module(tramite_json, [tramite_codigo_nombre_descripcion_motor/4,
			     categoria_de_nombre/2]).

/** <module> Capa de decision determinista para el dialogo.

Este modulo contiene la logica que NO necesita LLM:

  - modo_nlu/1: lee CHITA_NLU_MODE (hybrid | llm | rules).
  - acto_dialogo/2: clasifica la utterance completa en un acto de dialogo.
  - candidatos_tramite/2: busca tramites en el catalogo vivo.
  - candidatos_en_catalogo/3: version pura, para tests.
  - shortlist_tramites/3: top-K para el fallback del LLM.
  - resolver_candidato_previo/3: resuelve "1", "la de conducir", etc.

La extraccion de datos tipados sigue viviendo en gramatica.pl; este modulo
solo decide a nivel de dialogo y de busqueda de tramites.
*/

% ——————————————————————————————————————
% Modo de operacion
% ——————————————————————————————————————

%!  modo_nlu(-Modo) is det.
%
%   Modo es hybrid | llm | rules.
%     hybrid: reglas primero, LLM como respaldo (default).
%     llm:    comportamiento historico, LLM en la busqueda.
%     rules:  solo reglas, sin llamadas al LLM.
modo_nlu(Modo) :-
    (   catch(getenv('CHITA_NLU_MODE', Valor), _, fail)
    ->  texto_a_string(Valor, S0)
    ;   S0 = "hybrid"
    ),
    normalize_space(string(S1), S0),
    string_lower(S1, S),
    (   memberchk(S, ["hybrid","llm","rules"])
    ->  atom_string(Modo, S)
    ;   Modo = hybrid
    ).

%!  preguntas_llm_habilitadas is semidet.
%
%   En modo llm las preguntas usan el LLM.  En hybrid solo si se activa
%   CHITA_PREGUNTAS_LLM=1.  En rules nunca.
preguntas_llm_habilitadas :-
    modo_nlu(Modo),
    (   Modo == llm
    ->  true
    ;   Modo == hybrid,
        env_verdadero('CHITA_PREGUNTAS_LLM')
    ).

env_verdadero(Var) :-
    catch(getenv(Var, Valor), _, fail),
    texto_a_string(Valor, S0),
    normalize_space(string(S1), S0),
    string_lower(S1, S),
    memberchk(S, ["1","true","si","sí","yes","on"]).


% ——————————————————————————————————————
% Actos de dialogo
% ——————————————————————————————————————

%!  acto_dialogo(+Texto, -Acto) is det.
%
%   Acto es:
%     despedida | saludo | ayuda | afirmacion | negacion | ambiguo |
%     pausa | cancelacion | reanudacion | ninguno.
%
%   Solo se reconocen frases completas: "gracias, quiero sacar turno" no
%   es despedida y "necesito un turno" no es afirmacion.
acto_dialogo(Texto, Acto) :-
    (   es_despedida(Texto)
    ->  Acto = despedida
    ;   es_saludo(Texto)
    ->  Acto = saludo
    ;   es_ayuda(Texto)
    ->  Acto = ayuda
    ;   si_no(Texto, si)
    ->  Acto = afirmacion
    ;   si_no(Texto, no)
    ->  Acto = negacion
    ;   es_ambiguo_explicito(Texto)
    ->  Acto = ambiguo
    ;   control_tramite(Texto, pausar)
    ->  Acto = pausa
    ;   control_tramite(Texto, cancelar)
    ->  Acto = cancelacion
    ;   es_reanudacion(Texto)
    ->  Acto = reanudacion
    ;   Acto = ninguno
    ).

es_saludo(Texto) :-
    tokens(Texto, Tokens),
    Tokens \= [],
    frases_saludo(Frases),
    memberchk(Tokens, Frases).

frases_saludo([
    ["hola"],
    ["holi"],
    ["hey"],
    ["buenas"],
    ["buen","dia"],
    ["buenos","dias"],
    ["buenas","tardes"],
    ["buenas","noches"],
    ["que","tal"],
    ["hola","que","tal"],
    ["hola","buen","dia"],
    ["hola","buenas"],
    ["hola","buenas","tardes"],
    ["hola","buenas","noches"],
    ["hola","chita"],
    ["buen","dia","chita"]
]).

es_ayuda(Texto) :-
    tokens(Texto, Tokens),
    Tokens \= [],
    frases_ayuda(Frases),
    memberchk(Tokens, Frases).

frases_ayuda([
    ["ayuda"],
    ["ayudame"],
    ["necesito","ayuda"],
    ["me","ayudas"],
    ["que","podes","hacer"],
    ["que","puedes","hacer"],
    ["que","sabes","hacer"],
    ["que","puedo","hacer"],
    ["que","tramites","hay"],
    ["que","tramites","podes","hacer"],
    ["que","tramites","puedo","hacer"],
    ["como","funciona"],
    ["como","funciona","esto"],
    ["opciones"],
    ["menu"],
    ["para","que","sirves"],
    ["quien","sos"]
]).

es_reanudacion(Texto) :-
    (   control_tramite(Texto, continuar)
    ->  true
    ;   tokens(Texto, Tokens),
        Tokens \= [],
        frases_reanudacion(Frases),
        memberchk(Tokens, Frases)
    ).

frases_reanudacion([
    ["continuar"],
    ["continua"],
    ["continuemos"],
    ["seguir"],
    ["sigamos"],
    ["seguimos"],
    ["retomar"],
    ["retomo"],
    ["retomemos"],
    ["retomar","tramite"],
    ["continuar","tramite"],
    ["continuar","el","tramite"],
    ["seguir","con","el","tramite"],
    ["lo","pendiente"],
    ["el","pendiente"],
    ["mi","tramite","pendiente"],
    ["tramite","pendiente"],
    ["tramites","pendientes"],
    ["mis","tramites","pendientes"],
    ["que","quedo","pendiente"],
    ["donde","quede"],
    ["donde","quedo"],
    ["volver","al","tramite"],
    ["volver","al","tramite","pendiente"]
]).


% ——————————————————————————————————————
% Catalogo y candidatos
% ——————————————————————————————————————

%!  catalogo_actual(-Catalogo) is det.
%
%   Catalogo es una lista de dicts con codigo, nombre, entidad y categoria.
catalogo_actual(Catalogo) :-
    findall(_{codigo:Codigo, nombre:Nombre, entidad:Entidad, categoria:Categoria},
	    (   tramite_codigo_nombre_descripcion_motor(Codigo, Nombre0, _, Info),
		texto_a_string(Nombre0, Nombre),
		entidad_de_info(Info, Entidad),
		categoria_de_info(Info, Nombre0, Categoria)
	    ),
	    Candidatos0),
    dedup_por_codigo(Candidatos0, Catalogo).

entidad_de_info(Info, Entidad) :-
    (   is_dict(Info),
	get_dict(entidad, Info, Entidad0),
	Entidad0 \== ""
    ->  Entidad = Entidad0
    ;   Entidad = ""
    ).

categoria_de_info(Info, Nombre, Categoria) :-
    (   is_dict(Info),
	get_dict(categoria, Info, Categoria0),
	Categoria0 \== ""
    ->  Categoria = Categoria0
    ;   catch(categoria_de_nombre(Nombre, Categoria), _, fail)
    ->  true
    ;   Categoria = "otro"
    ).

dedup_por_codigo(Candidatos, Unicos) :-
    dedup_por_codigo(Candidatos, [], Unicos).

dedup_por_codigo([], _, []).
dedup_por_codigo([C|Cs], Vistos, Resto) :-
    (   memberchk(C.codigo, Vistos)
    ->  dedup_por_codigo(Cs, Vistos, Resto)
    ;   dedup_por_codigo(Cs, [C.codigo|Vistos], Resto0),
	Resto = [C|Resto0]
    ).

%!  candidatos_tramite(+Texto, -Resultado) is det.
%
%   Busca en el catalogo vivo.  Resultado es unico(Candidato),
%   varios([Candidato]) o ninguno.
candidatos_tramite(Texto, Resultado) :-
    catalogo_actual(Catalogo),
    candidatos_en_catalogo(Texto, Catalogo, Resultado).

%!  candidatos_en_catalogo(+Texto, +Catalogo, -Resultado) is det.
%
%   Version pura de candidatos_tramite/2.  Catalogo es una lista de dicts
%   con al menos nombre (y preferentemente codigo, entidad y categoria).
%
%   El puntaje combina cobertura de la consulta y precision sobre el nombre,
%   con fuzzy matching para typos y abreviaturas.  Los modificadores
%   "duplicado" y "renovacion" se penalizan si el usuario no los pidio.
candidatos_en_catalogo(Texto, Catalogo, Resultado) :-
    tokens_consulta(Texto, Tokens),
    (   Tokens == []
    ->  Resultado = ninguno
    ;   findall(CandidatoConPuntaje,
		(   member(Candidato, Catalogo),
		    is_dict(Candidato),
		    get_dict(nombre, Candidato, Nombre),
		    puntuar_nombre(Tokens, Nombre, Puntaje),
		    Puntaje >= 55,
		    put_dict(puntaje, Candidato, Puntaje, CandidatoConPuntaje)
		),
		Puntajes0),
	sort_candidatos(Puntajes0, Puntajes),
	decidir_candidatos(Puntajes, Resultado)
    ).

%!  shortlist_tramites(+Texto, +K, -Shortlist) is det.
%
%   Devuelve hasta K candidatos con puntaje positivo, ordenados de mayor a
%   menor.  Se usa como contexto acotado para el fallback del LLM.
shortlist_tramites(Texto, K, Shortlist) :-
    catalogo_actual(Catalogo),
    tokens_consulta(Texto, Tokens),
    (   Tokens == []
    ->  Shortlist = []
    ;   findall(CandidatoConPuntaje,
		(   member(Candidato, Catalogo),
		    is_dict(Candidato),
		    get_dict(nombre, Candidato, Nombre),
		    puntuar_nombre(Tokens, Nombre, Puntaje),
		    Puntaje > 0,
		    put_dict(puntaje, Candidato, Puntaje, CandidatoConPuntaje)
		),
		Puntajes0),
	sort_candidatos(Puntajes0, Puntajes),
	tomar_hasta(K, Puntajes, Shortlist)
    ).

sort_candidatos(Candidatos, Ordenados) :-
    predsort(comparar_candidato, Candidatos, Ordenados).

comparar_candidato(Orden, A, B) :-
    PA = A.puntaje,
    PB = B.puntaje,
    (   PA > PB
    ->  Orden = (<)
    ;   PA < PB
    ->  Orden = (>)
    ;   compare(Orden0, A.nombre, B.nombre),
	(   Orden0 == (=)
	->  compare(Orden, A.codigo, B.codigo)
	;   Orden = Orden0
	)
    ).

tomar_hasta(_, [], []).
tomar_hasta(0, _, []) :- !.
tomar_hasta(K, [C|Cs], [C|Resto]) :-
    K > 0,
    K1 is K - 1,
    tomar_hasta(K1, Cs, Resto).

decidir_candidatos([], ninguno).
decidir_candidatos([Top], unico(Top)) :-
    Top.puntaje >= 55,
    !.
decidir_candidatos([Top|Resto], Resultado) :-
    Top.puntaje >= 72,
    Resto = [Segundo|_],
    Margen is Top.puntaje - Segundo.puntaje,
    (   Margen >= 8
    ->  Resultado = unico(Top)
    ;   tomar_hasta(6, [Top|Resto], Lista),
	Resultado = varios(Lista)
    ),
    !.
decidir_candidatos([Top|Resto], Resultado) :-
    Top.puntaje >= 55,
    !,
    tomar_hasta(6, [Top|Resto], Lista),
    Resultado = varios(Lista).
decidir_candidatos(_, ninguno).


% ——————————————————————————————————————
% Puntaje por tokens
% ——————————————————————————————————————

puntuar_nombre(TokensConsulta, Nombre, Puntaje) :-
    tokens_consulta(Nombre, TokensNombre),
    (   TokensNombre == []
    ->  Puntaje = 0
    ;   contar_cubiertos(TokensConsulta, TokensNombre, CubiertosConsulta, FuzzyConsulta),
	contar_cubiertos(TokensNombre, TokensConsulta, CubiertosNombre, _),
	length(TokensConsulta, LConsulta),
	length(TokensNombre, LNombre),
	Cobertura is CubiertosConsulta / LConsulta,
	Precision is CubiertosNombre / LNombre,
	Base is 100 * Cobertura * (0.7 + 0.3 * Precision),
	penalizacion_modificadores(TokensConsulta, TokensNombre, Penalizacion),
	Puntaje0 is Base - Penalizacion - 4 * FuzzyConsulta,
	Puntaje is max(0, round(Puntaje0))
    ).

contar_cubiertos([], _, 0, 0).
contar_cubiertos([Token|Resto], Otros, Cubiertos, Fuzzy) :-
    (   once(token_coincide(Token, Otros, Tipo))
    ->  Cubiertos1 = 1,
	(   Tipo == exacto
	->  Fuzzy1 = 0
	;   Fuzzy1 = 1
	)
    ;   Cubiertos1 = 0,
	Fuzzy1 = 0
    ),
    contar_cubiertos(Resto, Otros, Cubiertos0, Fuzzy0),
    Cubiertos is Cubiertos0 + Cubiertos1,
    Fuzzy is Fuzzy0 + Fuzzy1.

token_coincide(Token, Otros, Tipo) :-
    (   memberchk(Token, Otros)
    ->  Tipo = exacto
    ;   (   member(Otro, Otros),
	    token_parecido(Token, Otro)
	)
    ->  Tipo = fuzzy
    ).

%!  token_parecido(+A, +B) is semidet.
%
%   Acepta truncamientos (>= 4 letras) y errores de tipeo chicos.
token_parecido(A, B) :-
    A \== B,
    string_length(A, LA),
    string_length(B, LB),
    Min is min(LA, LB),
    Min >= 4,
    (   sub_string(B, 0, LA, _, A)
    ;   sub_string(A, 0, LB, _, B)
    ;   Min =< 7,
	distancia_edicion(A, B, D),
	D =< 1
    ;   Min > 7,
	distancia_edicion(A, B, D),
	D =< 2
    ).

%!  distancia_edicion(+A, +B, -D) is det.
%
%   Levenshtein con programacion dinamica de dos filas.
distancia_edicion(A0, B0, Distancia) :-
    texto_a_string(A0, A),
    texto_a_string(B0, B),
    string_codes(A, CodesA),
    string_codes(B, CodesB),
    length(CodesB, LargoB),
    numlist(0, LargoB, Fila0),
    distancia_filas(CodesA, CodesB, Fila0, FilaFinal),
    last(FilaFinal, Distancia).

distancia_filas([], _, Fila, Fila).
distancia_filas([CA|RestoA], CodesB, FilaPrevia, FilaFinal) :-
    FilaPrevia = [Primero|RestoPrevio],
    Izquierda0 is Primero + 1,
    distancia_celdas(CodesB, CA, RestoPrevio, Izquierda0, Primero, Celdas),
    FilaActual = [Izquierda0|Celdas],
    distancia_filas(RestoA, CodesB, FilaActual, FilaFinal).

distancia_celdas([], _, _, _, _, []).
distancia_celdas([CB|RestoB], CA, [Arriba|RestoPrevio], Izquierda, Diagonal, [D|Resto]) :-
    (   CA == CB
    ->  Costo = 0
    ;   Costo = 1
    ),
    D is min(Arriba + 1, min(Izquierda + 1, Diagonal + Costo)),
    distancia_celdas(RestoB, CA, RestoPrevio, D, Arriba, Resto).

penalizacion_modificadores(TokensConsulta, TokensNombre, Penalizacion) :-
    findall(12,
	    (   member(Modificador, TokensNombre),
		es_modificador(Modificador),
		\+ once(token_coincide(Modificador, TokensConsulta, _))
	    ),
	    Penas),
    length(Penas, Cantidad),
    Penalizacion is 12 * Cantidad.

es_modificador("duplicado").
es_modificador("renovacion").


% ——————————————————————————————————————
% Normalizacion de la consulta
% ——————————————————————————————————————

tokens_consulta(Texto, Tokens) :-
    tokens(Texto, Tokens0),
    aplicar_alias_frases(Tokens0, Tokens1),
    maplist(alias_token, Tokens1, Tokens2),
    include(token_significativo, Tokens2, Tokens3),
    quitar_duplicados(Tokens3, Tokens).

aplicar_alias_frases(Tokens0, Tokens) :-
    reemplazar_subsecuencia(["capacidades","diferentes"], ["discapacidad"], Tokens0, T1),
    reemplazar_subsecuencia(["capacidad","diferente"], ["discapacidad"], T1, T2),
    reemplazar_subsecuencia(["partida","nacimiento"], ["certificado","nacimiento"], T2, T3),
    reemplazar_subsecuencia(["acta","nacimiento"], ["certificado","nacimiento"], T3, T4),
    reemplazar_subsecuencia(["partida","defuncion"], ["certificado","defuncion"], T4, T5),
    reemplazar_subsecuencia(["acta","defuncion"], ["certificado","defuncion"], T5, T6),
    reemplazar_subsecuencia(["constancia","domicilio"], ["certificado","residencia"], T6, T7),
    reemplazar_subsecuencia(["constancia","residencia"], ["certificado","residencia"], T7, T8),
    reemplazar_subsecuencia(["cambio","domicilio"], ["certificado","residencia"], T8, Tokens).

reemplazar_subsecuencia(De, A, Lista0, Lista) :-
    append(Prefijo, Resto, Lista0),
    append(De, Sufijo, Resto),
    !,
    append(Prefijo, A, Parcial),
    append(Parcial, Sufijo, Lista1),
    reemplazar_subsecuencia(De, A, Lista1, Lista).
reemplazar_subsecuencia(_, _, Lista, Lista).

alias_token(Token, Canonico) :-
    (   alias(Token, Canonico0)
    ->  Canonico = Canonico0
    ;   Canonico = Token
    ).

alias("escuela", "escolar").
alias("escuelas", "escolar").
alias("colegio", "escolar").
alias("colegios", "escolar").
alias("cole", "escolar").
alias("anotar", "inscripcion").
alias("anoto", "inscripcion").
alias("anotarme", "inscripcion").
alias("anotarlo", "inscripcion").
alias("anotarla", "inscripcion").
alias("inscribir", "inscripcion").
alias("inscribirme", "inscripcion").
alias("inscripto", "inscripcion").
alias("inscripciones", "inscripcion").
alias("auto", "vehiculo").
alias("autos", "vehiculo").
alias("coche", "vehiculo").
alias("coches", "vehiculo").
alias("vehiculos", "vehiculo").
alias("moto", "vehiculo").
alias("motos", "vehiculo").
alias("manejar", "conducir").
alias("manejo", "conducir").
alias("renovar", "renovacion").
alias("renuevo", "renovacion").
alias("renovando", "renovacion").
alias("renovaciones", "renovacion").
alias("duplicar", "duplicado").
alias("repetir", "duplicado").
alias("duplicados", "duplicado").
alias("constancia", "certificado").
alias("constancias", "certificado").
alias("certificados", "certificado").
alias("partida", "certificado").
alias("acta", "certificado").
alias("licencias", "licencia").
alias("permisos", "permiso").
alias("discapacitado", "discapacidad").
alias("discapacitada", "discapacidad").
alias("discapacitados", "discapacidad").
alias("vacuna", "vacunacion").
alias("vacunas", "vacunacion").
alias("casamiento", "matrimonio").
alias("casarme", "matrimonio").
alias("casar", "matrimonio").
alias("caso", "matrimonio").
alias("fallecimiento", "defuncion").
alias("muerte", "defuncion").
alias("antecedente", "antecedentes").
alias("penal", "penales").

token_significativo(Token) :-
    stopwords(Stopwords),
    \+ memberchk(Token, Stopwords).

stopwords([
    "a","al","algo","ahora","anda","ando","antes","aunque",
    "bien","buen","buena","buenas","bueno","buenos",
    "cada","como","con","cual","cuales","cuando","cuanto","cuanta",
    "de","del","desde","donde","dos","dias",
    "el","ella","ellas","ellos","en","entonces","es","esa","ese","eso","esta","este","esto","estoy",
    "favor","favor","fue",
    "gracias",
    "hacer","hago","hay","hice","hola",
    "iniciar","inicio","ir",
    "la","las","le","les","lo","los","luego",
    "me","mi","mis","muchas","mucho","muy",
    "nada","necesitaria","necesito","no","nos",
    "o","obtener","obtengo","otra","otro",
    "para","pedir","pido","podes","podia","podria","podrias","por","porfa","porque","puedo","puedes",
    "que","queria","queremos","queria","querer","quiero","quisiera",
    "sacar","saco","se","si","sin","solicitar","solicito","soy","su","sus",
    "te","tener","tengo","tramitar","tramite","tramites","tu","tus",
    "un","una","unas","uno","unos",
    "y","ya",
    "hijo","hija","hijos","hijas",
    "dia","tarde","tardes","noche","noches"
]).

quitar_duplicados([], []).
quitar_duplicados([X|Xs], [X|Ys]) :-
    delete(Xs, X, Resto),
    quitar_duplicados(Resto, Ys).


% ——————————————————————————————————————
% Seleccion sobre una lista ya mostrada
% ——————————————————————————————————————

%!  resolver_candidato_previo(+Texto, +Candidatos, -Resultado) is det.
%
%   Resuelve la respuesta del usuario cuando ya se mostro una lista.
%   Resultado es ok(Candidato), varios([Candidato]) o no_match.
resolver_candidato_previo(Texto, Candidatos, Resultado) :-
    is_list(Candidatos),
    Candidatos \== [],
    (   indice_seleccion(Texto, Indice)
    ->  (   nth1(Indice, Candidatos, Candidato)
	->  Resultado = ok(Candidato)
	;   Resultado = varios(Candidatos)
	)
    ;   candidatos_en_catalogo(Texto, Candidatos, Seleccion),
	(   Seleccion == ninguno
	->  Resultado = no_match
	;   Resultado = Seleccion
	)
    ).

indice_seleccion(Texto, Indice) :-
    tokens(Texto, Tokens),
    (   Tokens = [Unico]
    ;   Tokens = [_, Unico],
	memberchk("opcion", Tokens)
    ),
    (   catch(number_string(Indice0, Unico), _, fail)
    ->  Indice = Indice0
    ;   numero_en_palabras(Unico, Indice)
    ).

numero_en_palabras("uno", 1).
numero_en_palabras("dos", 2).
numero_en_palabras("tres", 3).
numero_en_palabras("cuatro", 4).
numero_en_palabras("cinco", 5).
numero_en_palabras("seis", 6).
numero_en_palabras("siete", 7).
numero_en_palabras("ocho", 8).
numero_en_palabras("nueve", 9).


% ——————————————————————————————————————
% Utilidades
% ——————————————————————————————————————

lista_candidatos_json(Candidatos, Json) :-
    findall(_{codigo:Codigo, nombre:Nombre, entidad:Entidad, categoria:Categoria},
	    (   member(Candidato, Candidatos),
		is_dict(Candidato),
		get_dict(codigo, Candidato, Codigo),
		get_dict(nombre, Candidato, Nombre),
		(   get_dict(entidad, Candidato, Entidad0) -> Entidad = Entidad0 ; Entidad = "" ),
		(   get_dict(categoria, Candidato, Categoria0) -> Categoria = Categoria0 ; Categoria = "otro" )
	    ),
	    Lista),
    atom_json_dict(Json, _{tramites:Lista}, [as(string)]).

%!  capitalizar(+Texto, -Capitalizado) is det.
capitalizar(Texto0, Texto) :-
    texto_a_string(Texto0, S0),
    (   S0 == ""
    ->  Texto = S0
    ;   string_codes(S0, [C|Cs]),
	(   C >= 0'a, C =< 0'z
	->  C1 is C - 32
	;   C1 = C
	),
	string_codes(Texto, [C1|Cs])
    ).

texto_a_string(Texto, String) :-
    (   string(Texto) -> String = Texto
    ;   atom(Texto) -> atom_string(Texto, String)
    ;   number(Texto) -> number_string(Texto, String)
    ;   is_list(Texto) -> string_codes(String, Texto)
    ;   format(string(String), "~w", [Texto])
    ).
