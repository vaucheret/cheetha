:- module(gramatica, [
			    prompt/1,
			    terminar//0,
			    es_despedida/1,
			    si_no/2,
			    es_ambiguo_explicito/1,
			    control_tramite/2,
			    normalizar_texto/2,
			    tokens/2,
			    extraer_respuesta_por_tipo/3,
			    extraer_dato/4
			]).
:- use_module(library(dcg/basics)).
:- use_module(library(lists), [memberchk/2, nth1/3, reverse/2]).
:- use_module(library(apply), [maplist/3, include/3, exclude/3]).
:- use_module(tramite_json).

/** <module> Este modulo tiene todos los predicados dcg para el
    analisis de texto del chatbot.

    La idea es que el vocabulario cerrado (despedidas, si/no, control de
    tramite, numeros, fechas y opciones) se resuelva de forma determinista.
    El LLM queda como respaldo para lenguaje abierto.
*/


% ——————————————————————————————————————
% Utilidades de texto
% ——————————————————————————————————————

texto_a_string(Texto, String) :-
    (   string(Texto) -> String = Texto
    ;   atom(Texto) -> atom_string(Texto, String)
    ;   number(Texto) -> number_string(Texto, String)
    ;   is_list(Texto) -> string_codes(String, Texto)
    ;   format(string(String), "~w", [Texto])
    ).

% Coincide con cualquier secuencia de codigos (incluida la vacia).
% Se define localmente para no depender de un init.pl del usuario.
... --> [] | [_], ... .

%!  normalizar_texto(+Texto, -Normalizado) is det.
%
%   Minusculas, sin acentos, sin puntuacion y con espacios colapsados.
%   Se usa para comparar frases completas (despedidas, si/no, control).
normalizar_texto(Texto0, Normalizado) :-
    texto_a_string(Texto0, S0),
    string_lower(S0, S1),
    sin_acentos(S1, S2),
    split_string(S2, " \t\n\r.,;:!?¡¿\"'()[]{}<>/\\|@#$%^&*+=~`-", " ", Partes0),
    quitar_vacios(Partes0, Partes1),
    quitar_tokens_ruido(Partes1, Partes),
    atomics_to_string(Partes, " ", Normalizado).

% Descarta tokens sin letras ni digitos (emojis, simbolos sueltos).
quitar_tokens_ruido([], []).
quitar_tokens_ruido([Token|Resto], Limpio) :-
    (   token_con_texto(Token)
    ->  Limpio = [Token|LimpioResto]
    ;   Limpio = LimpioResto
    ),
    quitar_tokens_ruido(Resto, LimpioResto).

token_con_texto(Token) :-
    string_codes(Token, Codes),
    memberchk(C, Codes),
    (   codigo_digito(C)
    ;   C >= 0'a, C =< 0'z
    ).

quitar_vacios([], []).
quitar_vacios([""|Resto], Limpio) :-
    !,
    quitar_vacios(Resto, Limpio).
quitar_vacios([Parte|Resto], [Parte|Limpio]) :-
    quitar_vacios(Resto, Limpio).

sin_acentos(S0, S1) :-
    string_codes(S0, C0),
    maplist(sin_acento_codigo, C0, C1),
    string_codes(S1, C1).

sin_acento_codigo(225, 97) :- !.    % á -> a
sin_acento_codigo(233, 101) :- !.   % é -> e
sin_acento_codigo(237, 105) :- !.   % í -> i
sin_acento_codigo(243, 111) :- !.   % ó -> o
sin_acento_codigo(250, 117) :- !.   % ú -> u
sin_acento_codigo(252, 117) :- !.   % ü -> u
sin_acento_codigo(241, 110) :- !.   % ñ -> n
sin_acento_codigo(C, C).

%!  tokens(+Texto, -Tokens) is det.
tokens(Texto, Tokens) :-
    normalizar_texto(Texto, Normalizado),
    (   Normalizado == ""
    ->  Tokens = []
    ;   split_string(Normalizado, " ", " ", Tokens0),
        quitar_vacios(Tokens0, Tokens)
    ).

limpiar_texto(Texto, Limpio) :-
    split_string(Texto, " \t\n\r", " \t\n\r", Partes0),
    quitar_vacios(Partes0, Partes),
    atomics_to_string(Partes, " ", Limpio).


% ——————————————————————————————————————
% Despedidas
% ——————————————————————————————————————

%!  es_despedida(+Texto) is semidet.
%
%   Verdadero solo si TODA la utterance es una despedida. Asi
%   "gracias, quiero sacar turno" no corta la conversacion.
es_despedida(Texto) :-
    tokens(Texto, Tokens),
    Tokens \= [],
    frases_despedida(Frases),
    memberchk(Tokens, Frases).

frases_despedida([
    ["gracias"],
    ["muchas","gracias"],
    ["mil","gracias"],
    ["gracias","por","todo"],
    ["gracias","por","la","ayuda"],
    ["gracias","por","tu","ayuda"],
    ["ok","gracias"],
    ["okay","gracias"],
    ["bueno","gracias"],
    ["listo","gracias"],
    ["perfecto","gracias"],
    ["genial","gracias"],
    ["chau"],
    ["chau","chau"],
    ["chao"],
    ["adios"],
    ["hasta","luego"],
    ["hasta","pronto"],
    ["hasta","la","vista"],
    ["hasta","manana"],
    ["nos","vemos"],
    ["nos","vemos","luego"],
    ["nos","vemos","pronto"],
    ["me","voy"],
    ["me","retiro"],
    ["cuidate"],
    ["que","te","vaya","bien"],
    ["que","tengas","un","buen","dia"],
    ["que","tengas","buen","dia"],
    ["salir"],
    ["terminar"],
    ["terminemos"],
    ["finalizar"],
    ["basta"],
    ["ya","esta"],
    ["gracias","hasta","luego"],
    ["muchas","gracias","hasta","luego"],
    ["hasta","luego","gracias"],
    ["hasta","pronto","gracias"],
    ["gracias","chau"],
    ["gracias","adios"],
    ["chau","gracias"],
    ["adios","gracias"],
    ["nos","vemos","gracias"],
    ["gracias","nos","vemos"]
]).

% Compatibilidad con el codigo viejo.  No usar con "..." alrededor:
% para eso esta es_despedida/1.
terminar --> "salir" ; "chau" ; "chao" ; "adios" ; "hasta luego" ;
             "hasta pronto" ; "nos vemos" ; "me voy".


% ——————————————————————————————————————
% Si / No / control
% ——————————————————————————————————————

%!  si_no(+Texto, -Valor) is det.
%
%   Valor es si | no | ambiguo.  Solo acepta la utterance completa.
si_no(Texto, Valor) :-
    tokens(Texto, Tokens),
    (   frases_ambiguas(FrasesA), memberchk(Tokens, FrasesA)
    ->  Valor = ambiguo
    ;   frases_si(FrasesS), memberchk(Tokens, FrasesS)
    ->  Valor = si
    ;   frases_no(FrasesN), memberchk(Tokens, FrasesN)
    ->  Valor = no
    ;   Valor = ambiguo
    ).

%!  es_ambiguo_explicito(+Texto) is semidet.
%
%   Verdadero solo si el usuario declaro ambiguedad con una frase conocida
%   ("no se", "tal vez", "depende").  No confundir con si_no/2, que devuelve
%   ambiguo tambien para cualquier frase desconocida.
es_ambiguo_explicito(Texto) :-
    tokens(Texto, Tokens),
    Tokens \= [],
    frases_ambiguas(Frases),
    memberchk(Tokens, Frases).

frases_ambiguas([
    ["no","se"],
    ["tal","vez"],
    ["depende"],
    ["quizas"],
    ["puede","ser"],
    ["no","estoy","seguro"],
    ["no","estoy","segura"],
    ["ni","idea"],
    ["como"],
    ["que"],
    ["por","que"],
    ["para","que"]
]).

frases_si([
    ["si"],
    ["dale"],
    ["de","una"],
    ["ok"],
    ["okey"],
    ["oka"],
    ["okay"],
    ["confirmo"],
    ["confirmado"],
    ["correcto"],
    ["claro"],
    ["claro","que","si"],
    ["por","supuesto"],
    ["adelante"],
    ["hagamoslo"],
    ["si","por","favor"],
    ["si","gracias"],
    ["si","dale"],
    ["si","confirmo"],
    ["obvio"],
    ["seguro"],
    ["afirmativo"],
    ["acepto"],
    ["perfecto"],
    ["buenisimo"],
    ["esta","bien"],
    ["va"],
    ["vamos"],
    ["hacelo"],
    ["ejecuta"],
    ["ejecutar"],
    ["iniciar"],
    ["empezar"]
]).

frases_no([
    ["no"],
    ["nop"],
    ["no","gracias"],
    ["no","por","favor"],
    ["para","nada"],
    ["negativo"],
    ["nunca"],
    ["jamas"],
    ["mejor","no"],
    ["otro"],
    ["equivocado"],
    ["incorrecto"],
    ["no","quiero"],
    ["no","me","interesa"],
    ["no","gracias","por","favor"],
    ["no","dale"],
    ["no","confirmo"]
]).

%!  control_tramite(+Texto, -Control) is det.
%
%   Control es pausar | cancelar | continuar | ninguno.
%   Se usa durante la ejecucion de un tramite, antes de extraer el dato.
control_tramite(Texto, Control) :-
    tokens(Texto, Tokens),
    (   frases_pausa(FrasesP), memberchk(Tokens, FrasesP)
    ->  Control = pausar
    ;   frases_cancelar(FrasesC), memberchk(Tokens, FrasesC)
    ->  Control = cancelar
    ;   frases_continuar(FrasesCont), memberchk(Tokens, FrasesCont)
    ->  Control = continuar
    ;   Control = ninguno
    ).

frases_pausa([
    ["pausar"],
    ["pausa"],
    ["despues"],
    ["mas","tarde"],
    ["luego"],
    ["lo","dejo","para","luego"],
    ["dejemoslo","para","luego"],
    ["seguimos","despues"],
    ["continuamos","despues"]
]).

frases_cancelar([
    ["cancelar"],
    ["cancela"],
    ["cancelo"],
    ["cancela","el","tramite"],
    ["cancelar","el","tramite"],
    ["no","quiero","seguir"],
    ["no","quiero","continuar"],
    ["dejalo"],
    ["dejemoslo"],
    ["me","arrepenti"],
    ["basta"],
    ["terminar","el","tramite"]
]).

frases_continuar([
    ["continuar"],
    ["continua"],
    ["seguir"],
    ["seguimos"],
    ["dale","seguir"],
    ["ok","continuar"],
    ["si","continuar"],
    ["vamos","seguir"]
]).


% ——————————————————————————————————————
% Extraccion de datos
% ——————————————————————————————————————

%!  extraer_dato(+Tipo, +Opciones, +Texto, -Resultado) is det.
%
%   Resultado es ok(Valor) | error(Motivo).
%   Tipo puede ser atomo o string: "numero", "fecha", "booleano", "texto".
extraer_dato(Tipo0, Opciones, Texto0, Resultado) :-
    texto_a_string(Tipo0, TipoS0),
    string_lower(TipoS0, Tipo),
    texto_a_string(Texto0, Texto),
    (   Tipo == "numero" -> extraer_numero(Texto, Resultado)
    ;   Tipo == "fecha" -> extraer_fecha(Texto, Resultado)
    ;   Tipo == "booleano" -> extraer_booleano(Texto, Resultado)
    ;   Tipo == "texto" -> extraer_texto(Opciones, Texto, Resultado)
    ;   Resultado = ok(Texto)
    ).

% Compatibilidad con el predicado viejo.  No recibe opciones.
extraer_respuesta_por_tipo(Tipo, LineS, Line1) :-
    texto_a_string(LineS, Texto),
    extraer_dato(Tipo, [], Texto, ok(Line1)).

extraer_booleano(Texto, Resultado) :-
    si_no(Texto, Valor),
    (   Valor == si -> Resultado = ok("si")
    ;   Valor == no -> Resultado = ok("no")
    ;   Resultado = error(ambiguo(booleano))
    ).

extraer_texto(Opciones, Texto, Resultado) :-
    (   is_list(Opciones), Opciones \= []
    ->  extraer_opcion(Opciones, Texto, Resultado)
    ;   es_despedida(Texto)
    ->  Resultado = error(despedida)
    ;   control_tramite(Texto, Control),
        Control \== ninguno
    ->  Resultado = error(control(Control))
    ;   limpiar_texto(Texto, Limpio),
        (   Limpio == "" -> Resultado = error(texto_vacio)
        ;   Resultado = ok(Limpio)
        )
    ).


% ——————————————————————————————————————
% Numero
% ——————————————————————————————————————

extraer_numero(Texto, Resultado) :-
    texto_a_string(Texto, S0),
    string_lower(S0, S1),
    sin_acentos(S1, S),
    split_string(S, " \t\n\r,;:!?¡¿\"'()[]{}<>\\|@#$%^&*+=~`/", " ", Partes0),
    quitar_vacios(Partes0, Partes),
    findall(Digitos,
            (   member(Token, Partes),
                limpiar_token_numerico(Token, TokenLimpio),
                token_numerico(TokenLimpio, Digitos)
            ),
            Candidatos0),
    sort(Candidatos0, Candidatos),
    (   Candidatos = [Numero] -> Resultado = ok(Numero)
    ;   Candidatos = [] -> extraer_numero_en_letras(Partes, Resultado)
    ;   Resultado = error(ambiguo(numero))
    ).

% Quita puntos/guiones al principio y al final de un token.  Un "20."
% al final de una frase sigue siendo el numero 20.
limpiar_token_numerico(Token, Limpio) :-
    string_codes(Token, Codes0),
    quitar_separadores_extremos(Codes0, Codes),
    string_codes(Limpio, Codes).

quitar_separadores_extremos([C|Resto], Limpio) :-
    (   C == 0'. ; C == 0'-
    ),
    !,
    quitar_separadores_extremos(Resto, Limpio).
quitar_separadores_extremos(Codes, Limpio) :-
    reverse(Codes, Rev0),
    quitar_separadores_extremos_rev(Rev0, Rev),
    reverse(Rev, Limpio).

quitar_separadores_extremos_rev([C|Resto], Limpio) :-
    (   C == 0'. ; C == 0'-
    ),
    !,
    quitar_separadores_extremos_rev(Resto, Limpio).
quitar_separadores_extremos_rev(Codes, Codes).

% Un token numerico es: digito (separador? digito)*
token_numerico(Token, Digitos) :-
    Token \= "",
    string_codes(Token, Codes),
    phrase(num_token, Codes),
    include(codigo_digito, Codes, DigitosCodes),
    length(DigitosCodes, Largo),
    Largo >= 1,
    Largo =< 15,
    string_codes(Digitos, DigitosCodes).

num_token --> digito, mas_num_token.
mas_num_token --> [].
mas_num_token --> digito, mas_num_token.
mas_num_token --> separador_num, digito, mas_num_token.
digito --> [C], { codigo_digito(C) }.
separador_num --> [C], { C == 0'. ; C == 0'- }.

codigo_digito(C) :-
    C >= 0'0,
    C =< 0'9.

% Numeros escritos con letras.  Se exige consumo total de la frase.
extraer_numero_en_letras(Partes, Resultado) :-
    (   numero_de_tokens(Partes, Numero)
    ->  number_string(Numero, TextoNumero),
        Resultado = ok(TextoNumero)
    ;   quitar_relleno_numerico(Partes, Limpias),
        Limpias \= Partes,
        numero_de_tokens(Limpias, Numero)
    ->  number_string(Numero, TextoNumero),
        Resultado = ok(TextoNumero)
    ;   Resultado = error(tipo_esperado(numero))
    ).

numero_de_tokens(Tokens, Numero) :-
    Tokens \= [],
    atomics_to_string(Tokens, " ", Texto),
    string_codes(Texto, Codes),
    findall(N, phrase(numero_en_letras(N), Codes), Numeros0),
    sort(Numeros0, [Numero]).

quitar_relleno_numerico(Tokens0, Tokens) :-
    quitar_prefijo_relleno(Tokens0, Tokens1),
    reverse(Tokens1, Rev1),
    quitar_prefijo_relleno(Rev1, Rev2),
    reverse(Rev2, Tokens).

quitar_prefijo_relleno([Token|Resto], Limpio) :-
    memberchk(Token, ["mi","mis","el","la","los","las","es","son",
                      "numero","nro","n","documento","dni","cuit","cuil",
                      "edad","anios","anos","pesos","dias","meses",
                      "de","del","y"]),
    !,
    quitar_prefijo_relleno(Resto, Limpio).
quitar_prefijo_relleno(Tokens, Tokens).


% ——————————————————————————————————————
% Fecha
% ——————————————————————————————————————

extraer_fecha(Texto, Resultado) :-
    texto_a_string(Texto, S0),
    string_lower(S0, S1),
    sin_acentos(S1, S),
    string_codes(S, Codes),
    (   catch(once(phrase((contexto_fecha, fecha_normalizada(dia(D),mes(M),año(A)), contexto_fecha), Codes)), _, fail),
        fecha_valida(D, M, A)
    ->  format(string(Fecha), "~d/~d/~d", [D, M, A]),
        Resultado = ok(Fecha)
    ;   catch(once(phrase((contexto_fecha, fecha_normalizada(_,_,_), contexto_fecha), Codes)), _, fail)
    ->  Resultado = error(fecha_invalida)
    ;   Resultado = error(tipo_esperado(fecha))
    ).

% Consume texto alrededor de la fecha sin partir un numero por la mitad.
% Los tramos de digitos se consumen completos, de modo que el parser de la
% fecha siempre ve el numero entero (p. ej. 2026, no 20 + 26).
contexto_fecha --> [].
contexto_fecha -->
    [C],
    { \+ codigo_digito(C) },
    contexto_fecha.
contexto_fecha -->
    digitos_codes(_),
    fin_digitos,
    contexto_fecha.

% Acepta tanto dia-mes-año como mes-dia-año.  Las clausulas de fecha/3
% usan ordenes de argumentos distintos, asi que se normalizan aca.
fecha_normalizada(dia(D), mes(M), año(A)) -->
    fecha(dia(D), mes(M), año(A)).
fecha_normalizada(dia(D), mes(M), año(A)) -->
    fecha(mes(M), dia(D), año(A)).

fecha_valida(D, M, A) :-
    integer(D), D >= 1, D =< 31,
    integer(M), M >= 1, M =< 12,
    integer(A), A >= 1900, A =< 2100,
    dias_del_mes(A, M, Max),
    D =< Max.

dias_del_mes(A, 2, 29) :-
    es_bisiesto(A),
    !.
dias_del_mes(_, 2, 28) :- !.
dias_del_mes(_, M, 30) :-
    memberchk(M, [4,6,9,11]),
    !.
dias_del_mes(_, _, 31).

es_bisiesto(A) :-
    A mod 4 =:= 0,
    (   A mod 100 =\= 0
    ;   A mod 400 =:= 0
    ).


% ——————————————————————————————————————
% Opciones
% ——————————————————————————————————————

extraer_opcion(Opciones, Texto, Resultado) :-
    tokens(Texto, TokensTexto),
    findall(opcion_norm(Indice, Valor, EtiquetaTokens, ValorTokens),
            (   nth1(Indice, Opciones, Opcion),
                opcion_valor_etiqueta(Opcion, Valor, Etiqueta),
                texto_a_string(Etiqueta, EtiquetaS),
                texto_a_string(Valor, ValorS),
                tokens(EtiquetaS, EtiquetaTokens),
                tokens(ValorS, ValorTokens)
            ),
            OpcionesNorm),
    (   OpcionesNorm == []
    ->  Resultado = error(opcion_invalida)
    ;   coincidencias_opcion(OpcionesNorm, TokensTexto, Coincidencias0),
        sort(Coincidencias0, Coincidencias),
        (   Coincidencias = [Valor]
        ->  texto_a_string(Valor, ValorS),
            Resultado = ok(ValorS)
        ;   Coincidencias = []
        ->  Resultado = error(opcion_invalida)
        ;   Resultado = error(ambiguo(opciones))
        )
    ).

opcion_valor_etiqueta(opcion(Valor, Etiqueta), Valor, Etiqueta) :-
    !.
opcion_valor_etiqueta(Valor, Valor, Valor).

coincidencias_opcion(OpcionesNorm, TokensTexto, Coincidencias) :-
    findall(Valor,
            (   member(opcion_norm(_, Valor, EtiquetaTokens, ValorTokens), OpcionesNorm),
                (   match_por_indice(TokensTexto, OpcionesNorm, Valor)
                ;   EtiquetaTokens == TokensTexto
                ;   ValorTokens == TokensTexto
                ;   coincidencia_parcial(TokensTexto, EtiquetaTokens)
                ;   coincidencia_parcial(TokensTexto, ValorTokens)
                )
            ),
            Coincidencias0),
    sort(Coincidencias0, Coincidencias).

% "1" o "opcion 1" selecciona la opcion 1 (1-based).
match_por_indice(TokensTexto, OpcionesNorm, Valor) :-
    (   TokensTexto = [Unico]
    ;   TokensTexto = [_, Unico],
        memberchk("opcion", TokensTexto)
    ),
    number_string(Indice, Unico),
    integer(Indice),
    Indice >= 1,
    member(opcion_norm(Indice, Valor, _, _), OpcionesNorm).

coincidencia_parcial(TokensTexto, TokensEtiqueta) :-
    quitar_stopwords(TokensTexto, Consulta),
    quitar_stopwords(TokensEtiqueta, Etiqueta),
    Consulta \= [],
    Etiqueta \= [],
    subconjunto(Consulta, Etiqueta).

subconjunto([], _).
subconjunto([X|Xs], Lista) :-
    memberchk(X, Lista),
    subconjunto(Xs, Lista).

quitar_stopwords(Tokens, Filtrados) :-
    exclude(es_stopword, Tokens, Filtrados).

es_stopword(Token) :-
    memberchk(Token, ["de","la","el","los","las","del","para","por",
                      "y","o","un","una","unos","unas","al"]).


% ——————————————————————————————————————
% Prompt de consola
% ——————————————————————————————————————

prompt(me)  :- write('Chatbot: ').
prompt(you) :- write('Usuario: ').


% ——————————————————————————————————————
% Numero (gramatica interna, usada por fechas)
% ——————————————————————————————————————

numero(N) --> ..., integer(N1),".",integer(N2),".",integer(N3), ... ,{N is N1 * 1000000 + N2 * 1000 + N3}.
numero(N) --> ..., integer(N) , ... .
numero(N) --> ..., lista_de_numero_en_letras(N),! , ... .
numero(N) --> ..., numero_en_letras(N), !, ... .

lista_de_numero_en_letras(N) -->
    lista_de_unidades(Lista),
    { convertir_lista_a_numero(Lista, N) }.

% --- Reconocer una lista de unidades separadas ---
lista_de_unidades([U|Us]) -->
    unidad(U),
    (" "|", "|","),
    lista_de_unidades(Us).
lista_de_unidades([U]) -->
    unidad(U).

% --- Convertir una lista de unidades en un número ---
convertir_lista_a_numero(Lista, Numero) :-
    foldl(combinar_digitos, Lista, 0, Numero).

combinar_digitos(Digito, Acumulado, Resultado) :-
    Resultado is Acumulado * 10 + Digito.

% --- Define lo que es un "número en letras" ---
numero_en_letras(N) --> miles_de_millones(N).
numero_en_letras(N) --> millones(N).
numero_en_letras(N) --> miles(N).
numero_en_letras(N) --> unidad_centena_millar(N). % (0-999)
numero_en_letras(0) --> "cero".

% --- Componente base: Números de 0 a 999 (unidad, decena, centena) ---
unidad_centena_millar(N) --> numero_complejo(N).
unidad_centena_millar(N) --> cientos_redondos(N).
unidad_centena_millar(N) --> numero_simple(N).

% --- Números simples (0-99) ---
numero_simple(N) --> numero_del_veinte_al_veintinueve(N).
numero_simple(N) --> numero_del_diez_al_diecinueve(N).
numero_simple(N) --> decena_y_unidad(N).
numero_simple(N) --> decena_redonda(N).
numero_simple(N) --> unidad(N).

% --- Unidades (1-9) ---
unidad(1) --> "uno".
unidad(1) --> "un".
unidad(1) --> "una".
unidad(2) --> "dos".
unidad(3) --> "tres".
unidad(4) --> "cuatro".
unidad(5) --> "cinco".
unidad(6) --> "seis".
unidad(7) --> "siete".
unidad(8) --> "ocho".
unidad(9) --> "nueve".

% --- Números del 10 al 19 ---
numero_del_diez_al_diecinueve(10) --> "diez".
numero_del_diez_al_diecinueve(11) --> "once".
numero_del_diez_al_diecinueve(12) --> "doce".
numero_del_diez_al_diecinueve(13) --> "trece".
numero_del_diez_al_diecinueve(14) --> "catorce".
numero_del_diez_al_diecinueve(15) --> "quince".
numero_del_diez_al_diecinueve(16) --> "dieciseis" ; "dieciséis".
numero_del_diez_al_diecinueve(17) --> "diecisiete".
numero_del_diez_al_diecinueve(18) --> "dieciocho".
numero_del_diez_al_diecinueve(19) --> "diecinueve".

% --- Números del 20 al 29 ---
numero_del_veinte_al_veintinueve(20) --> "veinte".
numero_del_veinte_al_veintinueve(21) --> "veintiuno" ; "veintiun" ; "veintiún" ; "veintiuna".
numero_del_veinte_al_veintinueve(22) --> "veintidos" ; "veintidós".
numero_del_veinte_al_veintinueve(23) --> "veintitres" ; "veintitrés".
numero_del_veinte_al_veintinueve(24) --> "veinticuatro".
numero_del_veinte_al_veintinueve(25) --> "veinticinco".
numero_del_veinte_al_veintinueve(26) --> "veintiseis" ; "veintiséis".
numero_del_veinte_al_veintinueve(27) --> "veintisiete".
numero_del_veinte_al_veintinueve(28) --> "veintiocho".
numero_del_veinte_al_veintinueve(29) --> "veintinueve".

% --- Decenas Redondas (20, 30, ..., 90) ---
decena_redonda(20) --> "veinte".
decena_redonda(30) --> "treinta".
decena_redonda(40) --> "cuarenta".
decena_redonda(50) --> "cincuenta".
decena_redonda(60) --> "sesenta".
decena_redonda(70) --> "setenta".
decena_redonda(80) --> "ochenta".
decena_redonda(90) --> "noventa".

% --- Decena y Unidad (ej: "treinta y cinco") ---
decena_y_unidad(N) -->
    decena_redonda(D),
    " y ",
    unidad(U),
    { N is D + U }.

% --- Cientos Redondos (100-900) ---
cientos_redondos(100) --> "cien".
cientos_redondos(200) --> "doscientos".
cientos_redondos(300) --> "trescientos".
cientos_redondos(400) --> "cuatrocientos".
cientos_redondos(500) --> "quinientos".
cientos_redondos(600) --> "seiscientos".
cientos_redondos(700) --> "setecientos".
cientos_redondos(800) --> "ochocientos".
cientos_redondos(900) --> "novecientos".

% --- Números complejos (ej: "ciento cincuenta y tres", "doscientos") ---
numero_complejo(N) -->
    "ciento",
    (   " ", numero_simple(S)
    ;   { S = 0 }
    ),
    { N is 100 + S }.
numero_complejo(N) -->
    cientos_redondos(C),
    { C \= 100 },
    (   " ", numero_simple(S)
    ;   { S = 0 }
    ),
    { N is C + S }.

% --- Nuevas Secciones: Miles, Millones, Miles de Millones ---

numero_hasta_miles(N) --> miles(N).
numero_hasta_miles(N) --> unidad_centena_millar(N).

numero_para_multiplicador(N) --> numero_hasta_miles(N).
numero_para_multiplicador(1) --> "un".

% --- Miles (1.000 - 999.999) ---
miles(N) -->
    "mil",
    (   (   " ", opt_reconocer(unidad_centena_millar, RestoUCM)
        ;   {RestoUCM = 0}
        ),
        { N is 1000 + RestoUCM }
    ).
miles(N) -->
    unidad_centena_millar(M),
    { M >= 2 },
    " mil",
    opt_espacio(_Espacio1),
    opt_reconocer(unidad_centena_millar, RestoUCM),
    { N is M * 1000 + RestoUCM }.

% --- Millones (1.000.000 - 999.999.999) ---
millones(N) -->
    numero_para_multiplicador(M),
    { M >= 1 },
    (" millon" ; " millón"),
    ( "es" ; { M = 1 } ),
    opt_espacio(_Espacio1),
    opt_reconocer(miles, RestoMiles),
    opt_espacio(_Espacio2),
    opt_reconocer(unidad_centena_millar, RestoUCM),
    { N is M * 1_000_000 + RestoMiles + RestoUCM }.
millones(1_000_000) --> "un millon".
millones(1_000_000) --> "un millón".

% --- Miles de Millones (1.000.000.000 - 999.999.999.999) ---
miles_de_millones(N) -->
    numero_para_multiplicador(M),
    { M >= 1 },
    " mil millones",
    opt_espacio(_Espacio1),
    opt_reconocer(millones, RestoMillones),
    opt_espacio(_Espacio2),
    opt_reconocer(miles, RestoMiles),
    opt_espacio(_Espacio3),
    opt_reconocer(unidad_centena_millar, RestoUCM),
    { N is M * 1_000_000_000 + RestoMillones + RestoMiles + RestoUCM }.
miles_de_millones(1_000_000_000) --> "mil millones".

% --- Predicados auxiliares ---
opt_reconocer(GrammarRule, Value) --> call(GrammarRule, Value), !.
opt_reconocer(_, 0) --> [].

opt_espacio(1) --> " ".
opt_espacio(0) --> [].


% ——————————————————————————————————————
% Fecha
% ——————————————————————————————————————

fecha(dia(D), mes(M), año(A)) --> dia(D), separador, mes(M), separador, año(A).
fecha(dia(D), mes(M), año(A)) --> año(A), separador, mes(M), separador, dia(D).
fecha(mes(M), dia(D), año(A)) --> mes(M), separador, dia(D), separador, año(A).
fecha(mes(M), dia(D), año(A)) --> mes(M), " ", dia(D), separador, año(A).

% Digitos contiguos.  fin_digitos impide que el parser consuma solo una
% parte de un numero (p. ej. "20" de "2026").
digitos_codes([C|Cs]) -->
    [C],
    { codigo_digito(C) },
    digitos_codes(Cs).
digitos_codes([C]) -->
    [C],
    { codigo_digito(C) }.

fin_digitos -->
    \+ ( [C], { codigo_digito(C) } ).

digitos_enteros(N) -->
    digitos_codes(Codes),
    fin_digitos,
    { number_codes(N, Codes) }.

dia(D) --> digitos_enteros(D), { D >= 1, D =< 31 }.

mes(M) --> digitos_enteros(M), { M >= 1, M =< 12 }.
mes(M) --> mes_nombre(M).

% Año de cuatro digitos o de dos (00-69 -> 2000-2069; 70-99 -> 1970-1999).
año(A) -->
    digitos_enteros(A0),
    {   (   A0 >= 0, A0 =< 99
        ->  (   A0 >= 70 -> A is 1900 + A0
            ;   A is 2000 + A0
            )
        ;   A0 > 999
        ->  A = A0
        ;   fail
        )
    }.

separador --> [0'/].
separador --> [0'-].
separador --> [0'.].
separador --> [0',].
separador --> " de " ; " del ".

mes_nombre(1) --> "ene";"enero".
mes_nombre(2) --> "feb";"febrero".
mes_nombre(3) --> "mar";"marzo".
mes_nombre(4) --> "abr";"abril".
mes_nombre(5) --> "may";"mayo".
mes_nombre(6) --> "jun";"junio".
mes_nombre(7) --> "jul";"julio".
mes_nombre(8) --> "ago";"agosto".
mes_nombre(9) --> "sep";"septiembre".
mes_nombre(10) --> "oct";"octubre".
mes_nombre(11) --> "nov";"noviembre".
mes_nombre(12) --> "dic";"diciembre".
