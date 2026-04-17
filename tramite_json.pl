:- module(tramite_json, [
	      cargar_tramites_from_url2/0,
	      cargar_tramites/0,
	      cargar_variables_tramite_en_espera/2,
	      tramite_disponible/1,
	      flujo_tramite/2,
	      informacion_tramite/6,
	      exportar_datos_tramite_kafka/6,
	      esperar_respuesta_kafka/4,
	      tramites_disponibles/1
	  ]).


/** <module> Libreria de Tramites

Este módulo implementa los predicados necesarios para
manejar los archivos donde se definen los tramites y contiene la
base de datos interna de los tramites, asi como los datos recolectados
*/


:- use_module(library(json)).
:- use_module(library(apply), [maplist/3, include/3, maplist/2]).
:- use_module(library(http/http_client), [http_post/4,http_get/3]).
:- use_module(persistencia).
     
    
:- dynamic tramite_disponible/1.
% informacion_tramite(Nombre,CodigoInterno,Asincronico,Auth,Descripcion,Automatizado)
:- dynamic informacion_tramite/6.
:- dynamic flujo_tramite/2.




tramites_disponibles(Tramites) :- findall(_{codigo:C,nombre:ST,descripcion:D}, (tramite_disponible(T),informacion_tramite(T,C,_,_,D,_),atom_string(T,ST)), L), atom_json_dict(Tramites, _{tramites:L},[as(string)]).

%!  directorio_tramites(Directory) is det.
%
%   Directorio donde se encuentran los archivos Json de los esquemas
%   de tramites

directorio_tramites("./tramites").

jsonfile -->  ...,".json".

jsonfiles(F) :-
    atom_codes(F,FC),
    phrase(jsonfile,FC).

cargar_tramite_desde_json(A) :-
    directorio_tramites(D),
    atomic_list_concat([D,"/",A],Archivo),
    open(Archivo, read, Stream, [encoding(utf8)]),
    json_read_dict(Stream, Dict),
    close(Stream),
    string_lower(Dict.'Tramite',NString),atom_string(Nombre,NString),
    assertz(tramite_disponible(Nombre)),
    assertz(informacion_tramite(Nombre,Dict.'CodigoInterno',Dict.'asincronico',Dict.'loginNecesario',Dict.'Identificacion',_{'Descripcion':Dict.'descripcion', 'Automatizado':false})),
    maplist(variable_a_paso, Dict.'Variables',Pasos),
    assertz(flujo_tramite(Nombre,Pasos)).

variable_a_paso(PDict,paso(Codigo, PDict.'Caption',PDict.'Tipo',Opciones)) :-
    atom_string(Codigo,PDict.'Codigo'),
    Opciones = PDict.get('Opciones',[]).


cargar_tramites :-
    directorio_tramites(D),
    directory_files(D,Fs),
    include(jsonfiles,Fs,Js),
    maplist(cargar_tramite_desde_json,Js).





cargar_tramites_from_url2 :-
    URL = 'https://thinknetc3.ddns.net/chita/apigps/api/Tramite/ListarConParametros?Ticket=qwqw',
		(
				catch(http_get(URL, Reply, [request_header('Content-Type'='application/json'),status_code(Code)]),_, fail),
				Code == 200
		->
		atom_json_term(Atom,Reply,[as(string)]),
		atom_json_dict(Atom, Dict, []),
		maplist(cargar_tramite_nuevo_desde_Json2,Dict.tramites)
		;   format("Error al descargar el archivo JSON desde la URL.~n")
		).
    


cargar_tramite_nuevo_desde_Json2(Diction) :-
                Dict = Diction.get('tramite'),
		Variables = Diction.get('variablesEntrada',[]),   
		string_lower(Dict.'nombre',NString),atom_string(Nombre,NString),
		assertz(tramite_disponible(Nombre)),
		assertz(informacion_tramite(Nombre,Dict.'codigo',Dict.'asincronico',Dict.'loginNecesario',Dict.'descripcion',_{'Automatizado':true})),
		maplist(variable_a_paso2, Variables,Pasos),
		assertz(flujo_tramite(Nombre,Pasos)).

variable_a_paso2(PDict,paso(Codigo, PDict.'label',Tipo,Opciones)) :-
    atom_string(Codigo,PDict.'codigo'),
    (	PDict.'clase' == 1 -> Tipo = "numero"
	      ;
	      (	  PDict.'clase' == 3 -> Tipo = "fecha"
			;
			(   PDict.'clase' == 6 -> Tipo = "booleano"
				  ;
				  Tipo = "texto"))),
    Opciones = PDict.get('Opciones',[]).

%% variable_a_paso3(PDict,paso(Codigo, PDict.'Label',Tipo,Opciones)) :-
%%     atom_string(Codigo,PDict.'Codigo'),
%%     (	PDict.'Clase' == 1 -> Tipo = "numero"
%% 	      ;
%% 	      (	  PDict.'Clase' == 3 -> Tipo = "fecha"
%% 			;
%% 			(   PDict.'Clase' == 6 -> Tipo = "booleano"
%% 				  ;
%% 				  Tipo = "texto"))),
%%     Opciones = PDict.get('Opciones',[]).


cargar_variables_tramite_en_espera(Variables,Pasos) :-
		maplist(variable_a_paso2, Variables,Pasos).


%% cargar_tramite_nuevo_desde_Json(Dict) :-
%%     string_lower(Dict.'nombre',NString),atom_string(Nombre,NString),
%%     assertz(tramite_disponible(Nombre)),
%%     assertz(informacion_tramite(Nombre,Dict.'codigo',Dict.'asincronico',Dict.'loginNecesario',Dict.'descripcion',true)).


    




%% exportar_datos_tramite(UserID,Tramite,TramiteID,Archivo) :-
%%     crearDictJsonTramite(UserID,Tramite,TramiteID,Dict,"tramitesResultados"),
%%     open(Archivo, write, Stream, [encoding(utf8)]),
%%     json_write_dict(Stream, Dict),
%%     close(Stream).


exportar_datos_tramite_kafka(UserID,Tramite,TramiteID,Topico,TopicoRes,Tokeninicio) :-
    crearDictJsonTramite(UserID,Tramite,TramiteID,Dict,TopicoRes,Tokeninicio),
    getenv('KAFKA_BRIDGE_URL', KafkaURL),
    atom_concat(KafkaURL,'/enviar_a_kafka', KafkaEndpoint),
    setup_call_cleanup(
        http_post(KafkaEndpoint,
                  json(_{ topic: Topico, mensaje: Dict }),
                  _,
                  [request_header('Content-Type'='application/json')]),
        true,
        true
    ).

crearDictJsonTramite(UserID,Tramite,TramiteID,Dict,TopicoRes,Tokeninicio) :-
    flujo_tramite(Tramite,Pasos),
    maplist(completar_variable(UserID,Tramite), Pasos, ListaVariables),
    informacion_tramite(Tramite,CodigoInterno,_,_,_,_),
    dict_create(Dict,_,['UsuarioChatBot':UserID, 'CodigoTramite':CodigoInterno,'TramiteID': TramiteID,'URLKafka':"66.70.179.213:9092",'TopicoKafka':TopicoRes, 'UsuarioKafka':"",'ClaveKafka':"",'TokenInicio':Tokeninicio,'Variables':ListaVariables]).

completar_variable(UserID,Tramite, paso(Id, _Caption,_Tipo,_Opciones), P) :-
    retract_dato_tramite(UserID,Tramite, Id, Valor),
		       atom_number(Id,IdChars),
		       dict_create(P,_,[
				       'CodigoVariable':IdChars,
				       'Valor':Valor
				   ]).



esperar_respuesta_kafka(UserID, Tramite,TramiteID, Resultado) :-
    informacion_tramite(Tramite,Codigo,_,_,_,_),
    getenv('KAFKA_BRIDGE_URL', KafkaURL),
    atom_concat(KafkaURL,'/resultado_tramite?usuario=~w&codigo=~w&id=~w', URLTemplate),
    format(string(URL), URLTemplate, [UserID,Codigo,TramiteID]),
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
    format(user_output, "Respuesta recibida de Kafka: ~w~n", [json(Datos)]),
    Datos.resultado = json(Result),
	Excepcion = Result.'Excepcion',
		(   Excepcion \= '' ->
		    format(string(Resultado),"⚠ Ocurrió un error en el trámite: ~s",[Excepcion])
		;     
    Respuestas = Result.'Variables',
    maplist(mensajecontenido, Respuestas, Strings),
    atomics_to_string(Strings,Resultado)
		)
    ;
    IntentosRest is Intentos -1,
    esperar_respuesta_loop(URL, Resultado, IntentosRest,Intervalo)
    ).

mensajecontenido(json(M),S) :-
    format(string(S),"~w descargar de  ~w ~n",[M.'Mensaje',M.'Contenido']).    



