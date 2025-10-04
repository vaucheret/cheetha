:- module(tramite_json, [
	      cargar_tramites/0,
	      cargar_tramite_desde_json/1,
	      cargar_tramites_from_one_Json/0,
	      tramite_disponible/1,
	      flujo_tramite/2,
	      codigo_interno/2,
	      identificacion_tramite/2,
	      exportar_datos_tramite/4,
	      exportar_datos_tramite_kafka/3,
	      esperar_respuesta_kafka/4,
	      dato_tramite/4
	  ]).


/** <module> Libreria de Tramites

Este módulo implementa los predicados necesarios para
manejar los archivos donde se definen los tramites y contiene la
base de datos interna de los tramites, asi como los datos recolectados
*/


:- use_module(library(http/json)).
:- use_module(library(apply), [maplist/3, include/3, maplist/2]).
:- use_module(library(http/http_client), [http_post/4,http_get/3]).

%:- use_module(library(readutil), [read_file_to_string/3]).

:- dynamic codigo_interno/2.
:- dynamic identificacion_tramite/2.
:- dynamic tramite_disponible/1.
:- dynamic flujo_tramite/2.
:- dynamic dato_tramite/4.



%!  directorio_tramites(Directory) is det.
%
%   Directorio donde se encuentran los archivos Json de los esquemas
%   de tramites

directorio_tramites("./tramites").

jsonfile -->  ...,".json".

jsonfiles(F) :-
    atom_codes(F,FC),
    phrase(jsonfile,FC).


cargar_tramites_from_one_Json :-
    open('listado_de_tramites.json',read,Stream,[encoding(utf8)]),
    json_read_dict(Stream, Dict),
    close(Stream),
    maplist(cargar_tramite_nuevo_desde_Json,Dict.tramites),
    findall(Nombre,tramite_disponible(Nombre),L),
    format("~n Tramites: ~n~n"),
    maplist([X]>>format('~a~n',[X]),L).


cargar_tramite_nuevo_desde_Json(Dict) :-
    string_lower(Dict.'nombre',NString),atom_string(Nombre,NString),
    assertz(tramite_disponible(Nombre)).

    

cargar_tramites :-
    directorio_tramites(D),
    directory_files(D,Fs),
    include(jsonfiles,Fs,Js),
    maplist(cargar_tramite_desde_json,Js).


cargar_tramite_desde_json(A) :-
    directorio_tramites(D),
    atomic_list_concat([D,"/",A],Archivo),
    open(Archivo, read, Stream, [encoding(utf8)]),
    json_read_dict(Stream, Dict),
    close(Stream),
    string_lower(Dict.'Tramite',NString),atom_string(Nombre,NString),
    assertz(tramite_disponible(Nombre)),
    assertz(codigo_interno(Nombre,Dict.'CodigoInterno')),
    assertz(identificacion_tramite(Nombre,Dict.'Identificacion')),
    maplist(variable_a_paso, Dict.'Variables',Pasos),
    assertz(flujo_tramite(Nombre,Pasos)).

variable_a_paso(PDict,paso(Codigo, PDict.'Caption',PDict.'Tipo',Opciones)) :-
    atom_string(Codigo,PDict.'Codigo'),
    Opciones = PDict.get('Opciones',[]).




exportar_datos_tramite(UserID,Tramite,TramiteID,Archivo) :-
    crearDictJsonTramite(UserID,Tramite,TramiteID,Dict),
    open(Archivo, write, Stream, [encoding(utf8)]),
    json_write_dict(Stream, Dict),
    close(Stream).


exportar_datos_tramite_kafka(UserID,Tramite,TramiteID) :-
    crearDictJsonTramite(UserID,Tramite,TramiteID,Dict),
    setup_call_cleanup(
        http_post('http://localhost:8090/enviar_a_kafka',
                  json(_{ topic: "tramites", mensaje: Dict }),
                  _,
                  [request_header('Content-Type'='application/json')]),
        true,
        true
    ).

crearDictJsonTramite(UserID,Tramite,TramiteID,Dict) :-
    flujo_tramite(Tramite,Pasos),
    maplist(completar_variable(UserID,Tramite), Pasos, ListaVariables),
%    atom_string(Tramite,TramiteS),
    codigo_interno(Tramite,CodigoInterno),
%    identificacion_tramite(Tramite,IdentificacionTramite),
    dict_create(Dict,_,['UsuarioChatBot':UserID, /*'Tramite':TramiteS,*/ 'CodigoTramite':CodigoInterno,'TramiteID': TramiteID,/*'Identificacion':IdentificacionTramite,*/ 'Variables':ListaVariables]).

completar_variable(UserID,Tramite, paso(Id, _Caption,_Tipo,_Opciones), P) :-
    retract(dato_tramite(UserID,Tramite, Id, Valor)),
		       atom_number(Id,IdChars),
		       dict_create(P,_,[
				       'CodigoVariable':IdChars,
%				       'Tipo':Tipo,
%				       'Opciones':Opciones,
				       'Valor':Valor
%				       'Caption':Caption
				   ]).



esperar_respuesta_kafka(UserID, Tramite,TramiteID, Resultado) :-
    codigo_interno(Tramite, Codigo),
    format(string(URL), 'http://localhost:8090/resultado_tramite?usuario=~w&codigo=~w&id=~w', [UserID,Codigo,TramiteID]),
%    format(string(URL), 'http://localhost:8090/resultado_tramite?usuario=~w&codigo=~w', [UserID,Codigo]),
    MaxIntentos = 30,
    IntervaloSeg = 2,
    esperar_respuesta_loop(URL, Resultado,MaxIntentos,IntervaloSeg).

esperar_respuesta_loop(_,"⚠ No se recibió respuesta en el tiempo límite.",0,_) :- !.
esperar_respuesta_loop(URL, Resultado,Intentos,Intervalo) :-
    sleep(Intervalo),
    (
	catch(http_get(URL, json(Datos), [request_header('Content-Type'='application/json'),status_code(Code)]), _, fail),

        Code == 200
    ->
    Datos.resultado = json(Result),
	Excepcion = Result.'Excepcion',
		(   Excepcion \= '' ->
		    format(string(Resultado),"⚠ Ocurrió un error en el trámite: ~s",[Excepcion])
		;     
    Respuestas = Result.'Variables',
    %% Respuestas = [json(First)|_],
    %% Mensaje = First.'Mensaje',
    %% Doc = First.'Contenido',
	  %% format(string(Resultado),"~s ~n descargar de ~s ~n",[Mensaje,Doc])
    maplist(mensajecontenido, Respuestas, Strings),
    atomics_to_string(Strings,Resultado)
			%    format(string(Resultado),"~s",[All])
		)
    ;
    IntentosRest is Intentos -1,
    esperar_respuesta_loop(URL, Resultado, IntentosRest,Intervalo)
    ).

mensajecontenido(json(M),S) :-
    format(string(S),"~w descargar de  ~w ~n",[M.'Mensaje',M.'Contenido']).    



%% esperar_respuesta_kafka(Tramite, Respuesta) :-
%%     format(atom(Archivo), "respuestas/respuesta_~w.json", [Tramite]),
%%     repeat,
%%     (   exists_file(Archivo)
%%     ->  read_file_to_string(Archivo, Contenido, []),
%%         atom_json_dict(Contenido, Dict, []),
%%         delete_file(Archivo),
%%         interpretar_respuesta_kafka(Dict, Respuesta),
%%         !
%%     ;   sleep(1), fail
%%     ).

%% interpretar_respuesta_kafka(Dict, Mensaje) :-
%%     Resultado = Dict.get(resultado, "proceso"),
%%     URL = Dict.get(url_pdf, ""),
%%     (
%%         Resultado = "aprobado",
%%         URL \= ""
%%     ->
%%         format(string(Mensaje), "✅ ¡Tu trámite fue aprobado!\n\nPuedes descargar el documento aquí: ~w", [URL])
%%     ;   Resultado = "aprobado"
%%     ->
%%         Mensaje = "✅ ¡Tu trámite fue aprobado!"
%%     ;   Resultado = "rechazado"
%%     ->
%%         Mensaje = "❌ Lamentablemente, tu trámite fue rechazado."
%%     ;   Mensaje = "ℹ️ Trámite recibido, en proceso."
%%     ).


