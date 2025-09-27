:- module(gramatica, [prompt/1,terminar//0,intencion/2,extraer_respuesta_por_tipo/3]).
:- use_module(library(dcg/basics)).
:- use_module(tramite_json).

/** <module> Este modulo tiene todos los predicados dcg para el
    analisis de texto del chatbot.
*/


extraer_respuesta_por_tipo(Tipo,LineS,Line1) :-
    (	Tipo == "numero" ->
	phrase(numero(N),LineS),
	number_string(N,Line1)
    ;	 
    (	Tipo == "fecha" ->
	phrase(fecha(dia(D),mes(M),año(A)),LineS),
	format(string(Line1),"~d/~d/~d",[D,M,A])
    ;
    (	
        Tipo == "booleano" ->
	phrase(booleana(Line1),LineS)
    ;
    (
	string_codes(Line1, LineS)
    )))).


prompt(me)  :- write('Chatbot: ').
prompt(you) :- write('Usuario: ').


terminar --> "salir";"chau";"gracias";"hasta luego";"me voy";"nos vemos".

intencion(InputS, iniciar_tramite(T)) :-
    phrase(respuesta_iniciar_tramite(T), InputS).


respuesta_iniciar_tramite(T) -->
     ...,  tramite(T), ... .

%% respuesta_iniciar_tramite(T) -->
%%     ..., ("quiero";"renovar";"sacar";"hacer";"obtener";"actualizar";"pedir"), ... , tramite(T), ... .


tramite(T) --> { tramite_disponible(T), atom_codes(T, Cs) }, seq(Cs).


/* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
   numero
- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

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
    " ",
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
numero_del_diez_al_diecinueve(16) --> "dieciseis".
numero_del_diez_al_diecinueve(17) --> "diecisiete".
numero_del_diez_al_diecinueve(18) --> "dieciocho".
numero_del_diez_al_diecinueve(19) --> "diecinueve".

% --- Números del 20 al 29 ---
numero_del_veinte_al_veintinueve(20) --> "veinte".
numero_del_veinte_al_veintinueve(21) --> "veintiuno".
numero_del_veinte_al_veintinueve(22) --> "veintidos".
numero_del_veinte_al_veintinueve(23) --> "veintitres".
numero_del_veinte_al_veintinueve(24) --> "veinticuatro".
numero_del_veinte_al_veintinueve(25) --> "veinticinco".
numero_del_veinte_al_veintinueve(26) --> "veintiseis".
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

% ¡NUEVA REGLA! Un número que puede ser unidad, centena, o miles (hasta 999.999)
numero_hasta_miles(N) --> miles(N).         % Prioriza si es una estructura de miles completa
numero_hasta_miles(N) --> unidad_centena_millar(N). % Si no, es hasta 999

% Un predicado auxiliar para la cantidad antes de "mil", "millón" o "mil millones" (1-999)
% Este se usa para el número que *multiplica* la unidad de medida.
% Modificado para usar numero_hasta_miles cuando el multiplicador es mayor que 999
numero_para_multiplicador(N) --> numero_hasta_miles(N).
numero_para_multiplicador(1) --> "un". % Para "un millon", "un mil millones"


% --- Miles (1.000 - 999.999) ---
miles(N) --> "mil", % Caso específico para 1000
    (   (   " ", opt_reconocer(unidad_centena_millar, RestoUCM)
        ;   {RestoUCM = 0}
        ),
        { N is 1000 + RestoUCM }
    ).
miles(N) -->
    unidad_centena_millar(M), % Solo hasta 999 para el prefijo de "mil"
    { M >= 2 }, % "dos mil", "ciento cincuenta mil", no "un mil"
    " mil",
    opt_espacio(_Espacio1),
    opt_reconocer(unidad_centena_millar, RestoUCM),
    { N is M * 1000 + RestoUCM }.
% Para "un mil" que es raro, se cubre con la primera regla "mil"


% --- Millones (1.000.000 - 999.999.999) ---
millones(N) -->
    numero_para_multiplicador(M), % ¡Ahora puede ser un numero_hasta_miles!
    { M >= 1 },
    " millon",
    ( "es" ; { M = 1 } ),
    opt_espacio(_Espacio1),
    opt_reconocer(miles, RestoMiles),
    opt_espacio(_Espacio2),
    opt_reconocer(unidad_centena_millar, RestoUCM),
    { N is M * 1_000_000 + RestoMiles + RestoUCM }.
millones(1_000_000) --> "un millon".

% --- Miles de Millones (1.000.000.000 - 999.999.999.999) ---
miles_de_millones(N) -->
    numero_para_multiplicador(M), % ¡Ahora puede ser un numero_hasta_miles!
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



/* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
   fecha
- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

fecha(dia(D), mes(M), año(A)) --> ... , dia(D), separador, mes(M), separador, año(A), ... .
fecha(dia(D), mes(M), año(A)) --> ... , año(A), separador, mes(M), separador, dia(D), ... .
fecha(mes(M), dia(D), año(A)) --> ... , mes(M), separador, dia(D), separador, año(A), ... .



%dia(D) --> integer(D),{ D >= 1 , D =< 31}.
dia(D) --> numero(D),{ D >= 1 , D =< 31}.
    

mes(M) --> integer(M), {number(M), M >= 1, M =< 12}.
mes(M) --> mes_nombre(M).


año(A) --> numero(A), { A > 999}.


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
mes_nombre(9) --> "sep";"setptiembre".
mes_nombre(10) --> "oct";"octubre".
mes_nombre(11) --> "nov";"noviembre".
mes_nombre(12) --> "dic";"diciembre".

/* - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
   boleana (si,no)
   - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - */

booleana("si") --> ... , si, ... .
booleana("no") --> ... , no, ... .

si --> "si " ;  " si" ; "si," ; "si." ; "si" ; "sí" ; "afirmativamente" ; "afirmativo" .
no --> "no " ; " no" ; "no," ; "no." ; "no" ; "negativo" ; "ninguna" .


