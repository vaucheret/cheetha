:- module(tramite_json, [
			    cargar_tramite_desde_ril/0,
			    cargar_tramites_from_url2/0,
			    cargar_tramites/0,
			    cargar_variables_tramite_en_espera/2,
			    tramite_codigo_nombre_descripcion_motor/4,
			    flujo_tramite_codigo_pasos/2,
			    % tramite_disponible/1,
			    % flujo_tramite/2,
			    % informacion_tramite/6,
			    exportar_datos_tramite_kafka/5,
			    %	      esperar_respuesta_kafka/4,
			    tramites_disponibles/1,
			    categoria_de_nombre/2
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
:- use_module(library(date), [parse_time/2]).
     
:- dynamic tramite_codigo_nombre_descripcion_motor/4.  % tramite_codigo_descripcion(Codigo,Nombre,Descripcion,
                                                       % _{codigochita:atom,automatizado:bool,descripcion:string,asincronico:bool,loginNecesario:num})
:- dynamic flujo_tramite_codigo_pasos/2.


%:- dynamic tramite_disponible/1.
                                                       % informacion_tramite(Nombre,CodigoInterno,Asincronico,Auth,Descripcion,Automatizado)
%:- dynamic informacion_tramite/6.
%:- dynamic flujo_tramite/2.


:- dynamic token_gps/2.  % token_gps(Token, FechaVencimiento)

obtener_token_valido(Token) :-
    (   token_gps(TokenActual, FechaVenc),
        get_time(TiempoActual),
        parse_time(FechaVenc, TiempoVenc),
	% Agregar margen de 5 horas (18000 segundos) por diferencia horaria
        TiempoVencSeguro is TiempoVenc - 18000,
        TiempoActual < TiempoVencSeguro
    ->  % Token válido
        Token = TokenActual
    ;   % Token vencido o no existe, obtener nuevo
        obtener_nuevo_token(Token)
    ).

obtener_nuevo_token(Token) :-
    (   getenv('GPS_TOKEN_URL', URL) -> true
    ;   URL = 'https://thinknetc3.ddns.net/chitaV2/APIGPS/api/Login/ObtenerToken?Usuario=fcuello&Clave=fc1234%21'
    ),
    catch(
        (   http_get(URL, Reply, [request_header('Content-Type'='application/json'), status_code(Code)]),
            Code == 200,
            atom_json_term(Atom, Reply, [as(string)]),
            atom_json_dict(Atom, Dict, []),
            TokenString = Dict.token,
	    % Asegurar que el token sea un átomo
            (   atom(TokenString) -> 
                Token = TokenString
            ;   atom_string(Token, TokenString)
            ),
            FechaVenc = Dict.vencimiento,
            % Limpiar token anterior y guardar nuevo
            retractall(token_gps(_, _)),
            assertz(token_gps(Token, FechaVenc))
        ),
        Error,
        (   format("Error obteniendo token: ~w~n", [Error]),
            fail
        )
    ).

tramites_disponibles(Tramites) :-
    findall(_{codigo:C, nombre:ST, entidad:E, categoria:Cat},
            (tramite_codigo_nombre_descripcion_motor(C,T,_,DictMotor),
             atom_string(T,ST),
             E = DictMotor.get(entidad, ""),
             categoria_de_nombre(T, Cat)),
            L),
    atom_json_dict(Tramites, _{tramites:L}, [as(string)]).

categoria_de_nombre(Nombre, "certificado") :- sub_atom(Nombre, 0, _, _, "certificado"), !.
categoria_de_nombre(Nombre, "duplicado") :- sub_atom(Nombre, 0, _, _, "duplicado"), !.
categoria_de_nombre(Nombre, "renovación") :- sub_atom(Nombre, 0, _, _, "renovación"), !.
categoria_de_nombre(Nombre, "inscripción") :- sub_atom(Nombre, 0, _, _, "inscripción"), !.
categoria_de_nombre(Nombre, "licencia") :- sub_atom(Nombre, 0, _, _, "licencia"), !.
categoria_de_nombre(Nombre, "permiso") :- sub_atom(Nombre, 0, _, _, "permiso"), !.
categoria_de_nombre(Nombre, "libre_deuda") :- sub_atom(Nombre, 0, _, _, "libre deuda"), !.
categoria_de_nombre(Nombre, "credencial") :- sub_atom(Nombre, 0, _, _, "crear credencial"), !.
categoria_de_nombre(_, "otro").

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
    categoria_de_nombre(Nombre, Cat),
    assertz(tramite_codigo_nombre_descripcion_motor(Dict.'CodigoInterno',Nombre,Dict.'Identificacion',_{'Automatizado':false,'Descripcion':Dict.'descripcion',asincronico:Dict.'asincronico',loginNecesario:Dict.'loginNecesario',entidad:"",categoria:Cat})),
    %    assertz(tramite_disponible(Nombre)),
    %    assertz(informacion_tramite(Nombre,Dict.'CodigoInterno',Dict.'asincronico',Dict.'loginNecesario',Dict.'Identificacion',_{'Descripcion':Dict.'descripcion', 'Automatizado':false})),
    maplist(variable_a_paso, Dict.'Variables',Pasos),
    assertz(flujo_tramite_codigo_pasos(Dict.'CodigoInterno',Pasos)).
%    assertz(flujo_tramite(Nombre,Pasos)).

variable_a_paso(PDict,paso(Codigo, PDict.'Caption',PDict.'Caption',PDict.'Tipo',Opciones)) :-
    atom_string(Codigo,PDict.'Codigo'),
    Opciones = PDict.get('Opciones',[]).


cargar_tramites :-
    directorio_tramites(D),
    directory_files(D,Fs),
    include(jsonfiles,Fs,Js),
    maplist(cargar_tramite_desde_json,Js).


cargar_tramite_desde_ril :-
    (   getenv('RIL_TRAMITES_URL', URL) -> true
    ;   URL = 'https://thinknetc3.ddns.net/chitaV2/APIRIL/api/TramitesRIL/ListarTramitesSimulados'
    ),
    %    URL = 'https://thinknetc3.ddns.net/chitav2/apiril/api/TramitesRIL/ListarTramites',
    (
	catch(http_get(URL, Reply, [request_header('Content-Type'='application/json'),status_code(Code)]),_, fail),
	Code == 200
    ->
	atom_json_term(Atom,Reply,[as(string)]),
	atom_json_dict(Atom, Dict, []),
	maplist(cargar_tramite_nuevo_desde_JsonRil,Dict.tramites)
    ;   format("Error al descargar el archivo JSON desde la URL.~n")
    ).



cargar_tramites_from_url2 :-
    (   getenv('GPS_TRAMITES_URL', URL) -> true
    ;   URL = 'https://thinknetc3.ddns.net/chitav2/apigps/api/Tramite/ListarConParametros?Ticket=qwqw'
    ),
    (
	obtener_token_valido(Token),
	catch(http_get(URL, Reply, [
				       request_header('Content-Type'='application/json'),
				       authorization(bearer(Token)),
				       status_code(Code)
				   ]),_, fail),
	Code == 200
    ->
	atom_json_term(Atom,Reply,[as(string)]),
	atom_json_dict(Atom, Dict, []),
	maplist(cargar_tramite_nuevo_desde_Json2,Dict.tramites)
    ;   format("Error al descargar el archivo JSON desde la URL.~n")
    ).
    
cargar_tramite_nuevo_desde_JsonRil(Dictionbase) :-
    Diction = Dictionbase.'definicion',
    string_lower(Diction.'nombre',NString),atom_string(Nombre,NString),
    %%    assertz(tramite_disponible(Nombre)),
    % format(string(URL),"https://thinknetc3.ddns.net/chitav2/apiril/api/TramitesRIL/SimularTramite?Codigo=~w",[Diction.'id_Tramite']),
    % (
    % 	catch(http_get(URL, Reply, [request_header('Content-Type'='application/json'),
    % 				    status_code(Code)]),_, fail),
    % 	Code == 200
    % ->
    % 	atom_json_term(Atom,Reply,[as(string)]),
    % 	atom_json_dict(Atom, Dict, []),
    phrase(("\n Requisitos: \n",variable_a_string(Dictionbase.requisitos)),Req),
    string_codes(Requisitos,Req),
    % ;   format("Error al descargar el archivo JSON desde la URL.~n")
    % ),
    Descripcion = Diction.descripcion,
    categoria_de_nombre(Nombre, Cat),
    E = Dictionbase.get(entidad, ""),
    AI = Dictionbase.get(areaInterna, ""),
    assertz(tramite_codigo_nombre_descripcion_motor(Diction.'id_Tramite',Nombre,Descripcion,_{'codigochita':Diction.'codigoChita','Automatizado':Diction.'automatizado','Descripcion':Requisitos,entidad:E,areaInterna:AI,categoria:Cat})).
%%  assertz(informacion_tramite(Nombre,Diction.'id_Tramite',false,0,Diction.'descripcion',_{'Descripcion':Requisitos,'Automatizado':false})).
	


cargar_tramite_nuevo_desde_Json2(Diction) :-
    Dict = Diction.get('tramite'),
    Variables = Diction.get('variablesEntrada',[]),   
    %		string_lower(Dict.'nombre',NString),atom_string(Nombre,NString),
    C = Dict.'codigoRIL',
    (
	C == -1
    -> true
    ;
	%%		assertz(tramite_disponible(Nombre)),
	%%		assertz(informacion_tramite(Nombre,Dict.'codigo',Dict.'asincronico',Dict.'loginNecesario',Dict.'descripcion',_{'Automatizado':true})),
	retract(tramite_codigo_nombre_descripcion_motor(C,Nombre,D,Info)),
	Info.codigochita = Dict.'codigo',
	assertz(tramite_codigo_nombre_descripcion_motor(C,Nombre,D,Info.put(asincronico,Dict.'asincronico').put(loginNecesario,Dict.'loginNecesario'))),	
	maplist(variable_a_paso2, Variables,Pasos),
	assertz(flujo_tramite_codigo_pasos(Dict.'codigo',Pasos))
    ).


variable_a_string([]) --> [].
variable_a_string([PDict|Rest]) -->
    format_("- ~w Expedido por: ~w ~n", [PDict.'descripcion', PDict.'expedidoPor']),
    variable_a_string(Rest).


variable_a_paso3(PDict,paso(Codigo, "",PDict.'label',Tipo,Opciones)) :-
    atom_string(Codigo,PDict.'codigo'),
    (	PDict.'clase' == 1 -> Tipo = "numero"
    ;
	(	  PDict.'clase' == 3 -> Tipo = "fecha"
	;
		  (   PDict.'clase' == 6 -> Tipo = "booleano"
		  ;
		      Tipo = "texto"))),
    ListOpciones = PDict.get('listaquery',[]),
    (
	normalizaropciones(ListOpciones,Opciones) ->
	true
    ;
	Opciones = []
    ).


variable_a_paso2(PDict,paso(Codigo, PDict.'nombre',PDict.'label',Tipo,Opciones)) :-
    atom_string(Codigo,PDict.'codigo'),
    (	PDict.'clase' == 1 -> Tipo = "numero"
    ;
	(	  PDict.'clase' == 3 -> Tipo = "fecha"
	;
		  (   PDict.'clase' == 6 -> Tipo = "booleano"
		  ;
		      Tipo = "texto"))),
    ListOpciones = PDict.get('listaquery',[]),
    (
	normalizaropciones(ListOpciones,Opciones) ->
	true
    ;
	Opciones = []
    ).
	

normalizaropciones([],[]).
normalizaropciones([X,Y|R],[opcion(X,Y)|S]):-
    normalizaropciones(R,S).

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
    maplist(variable_a_paso3, Variables,Pasos).


exportar_datos_tramite_kafka(UserID,Tramite,TramiteID,Tokeninicio,Contexto) :-
    crearDictJsonTramite(UserID,Tramite,TramiteID,Tokeninicio,Contexto,Dict),
    getenv('KAFKA_BRIDGE_URL', KafkaURL),
    atom_concat(KafkaURL,'/enviar_a_kafka', KafkaEndpoint),
    setup_call_cleanup(
        http_post(KafkaEndpoint,
                  json(_{ topic: Contexto.topic, url: Contexto.url,  mensaje: Dict }),
                  _,
                  [request_header('Content-Type'='application/json')]),
        true,
        true
    ).

crearDictJsonTramite(UserID,Tramite,TramiteID,Tokeninicio,Contexto,
		     Dict) :-
    %    flujo_tramite_codigo_pasos(Tramite,Pasos),
    findall(P,completar_variable(UserID,Tramite,TramiteID,P),ListaVariables),
    retractdatos(UserID,Tramite,TramiteID,ListaVariables),
    %    maplist(completar_variable(UserID,Tramite), % Pasos,
    %	    ListaVariables),
    %   informacion_tramite(Tramite,CodigoInterno,_,_,_,_),
    dict_create(Dict,_,
		[
		    'Accion': Contexto.accion,
		    'UsuarioChatBot':UserID,
		    'CodigoTramite':Tramite,
		    'TramiteID': TramiteID,
		    'InstanciaTramite': Contexto.instanciatramite,
		    'InstanciaStep': Contexto.instanciastep,
		    'CodigoStep': Contexto.codigostep,
		    'URLKafkaEE': Contexto.url,
		    'TopicoKafkaEE': Contexto.topic,
		    'UsuarioKafkaEE':"",
		    'ClaveKafkaEE':"",
		    'URLKafka': Contexto.urlmotor,
		    'TopicoKafka': Contexto.topicomotor,
		    'UsuarioKafka':"",
		    'ClaveKafka':"",
		    'TokenInicio':Tokeninicio,
		    'Variables':   ListaVariables
		]).


% exportar_datos_tramite_kafka(UserID,Tramite,TramiteID,Topico,TopicoRes,Tokeninicio) :-
%     crearDictJsonTramite(UserID,Tramite,TramiteID,Dict,TopicoRes,Tokeninicio),
%     getenv('KAFKA_BRIDGE_URL', KafkaURL),
%     atom_concat(KafkaURL,'/enviar_a_kafka', KafkaEndpoint),
%     setup_call_cleanup(
%         http_post(KafkaEndpoint,
%                   json(_{ topic: Topico, mensaje: Dict }),
%                   _,
%                   [request_header('Content-Type'='application/json')]),
%         true,
%         true
%     ).

% crearDictJsonTramite(UserID,Tramite,TramiteID,Dict,TopicoRes,Tokeninicio) :-
%     flujo_tramite_codigo_pasos(Tramite,Pasos),
%     maplist(completar_variable(UserID,Tramite), Pasos, ListaVariables),
%  %   informacion_tramite(Tramite,CodigoInterno,_,_,_,_),
%     dict_create(Dict,_,
% 		[
% 		    'UsuarioChatBot':UserID,
% 		    'CodigoTramite':Tramite,
% 		    'TramiteID': TramiteID,
% 		    'URLKafka':"66.70.179.213:9092",
% 		    'TopicoKafka':TopicoRes,
% 		    'UsuarioKafka':"",
% 		    'ClaveKafka':"",
% 		    'TokenInicio':Tokeninicio,
% 		    'Variables':   ListaVariables
% 		]).

retractdatos(_UserID,_Tramite,_Tramid,[]).
retractdatos(UserID,Tramite,Tramid,[_{'CodigoVariable': IdChars,'Valor': _}|ListaVariables]):-
    atom_number(Id,IdChars),
    retract_dato_tramite(UserID,Tramite,Tramid,Id,_),
    retractdatos(UserID,Tramite,Tramid,ListaVariables).


completar_variable(UserID,Tramite,Tramid, % paso(Id,_Nombre, _Caption,_Tipo,_Opciones),
		   P) :-
    dato_tramite(UserID,Tramite,Tramid, Id, Valor),
    atom_number(Id,IdChars),
    dict_create(P,_,[
			'CodigoVariable':IdChars,
			'Valor':Valor
		    ]).



% esperar_respuesta_kafka(UserID, Tramite,TramiteID, Resultado) :-
%   %  informacion_tramite(Tramite,Codigo,_,_,_,_),
%     getenv('KAFKA_BRIDGE_URL', KafkaURL),
%     atom_concat(KafkaURL,'/resultado_tramite?usuario=~w&codigo=~w&id=~w', URLTemplate),
%     format(string(URL), URLTemplate, [UserID,Tramite,TramiteID]),
%     MaxIntentos = 30,
%     IntervaloSeg = 2,
%     esperar_respuesta_loop(URL, Resultado,MaxIntentos,IntervaloSeg).

% esperar_respuesta_loop(_,"⚠ No se recibió respuesta en el tiempo límite.",0,_) :- !.
% esperar_respuesta_loop(URL, Resultado,Intentos,Intervalo) :-
%     sleep(Intervalo),
%     (
% 	catch(http_get(URL, json(Datos), [request_header('Content-Type'='application/json'),status_code(Code)]), _, fail),
%         Code == 200
%     ->
%     format(user_output, "Respuesta recibida de Kafka: ~w~n", [json(Datos)]),
%     Datos.resultado = json(Result),
% 	Excepcion = Result.'Excepcion',
% 		(   Excepcion \= '' ->
% 		    format(string(Resultado),"⚠ Ocurrió un error en el trámite: ~s",[Excepcion])
% 		;     
%     Respuestas = Result.'Variables',
%     maplist(mensajecontenido, Respuestas, Strings),
%     atomics_to_string(Strings,Resultado)
% 		)
%     ;
%     IntentosRest is Intentos -1,
%     esperar_respuesta_loop(URL, Resultado, IntentosRest,Intervalo)
%     ).

% mensajecontenido(json(M),S) :-
%     format(string(S),"~w descargar de  ~w ~n",[M.'Mensaje',M.'Contenido']).    



