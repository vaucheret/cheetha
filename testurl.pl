:- module(testurl, [testget/0,testget2/0]).

:- use_module(library(http/json)).
:- use_module(library(http/http_client), [http_post/4,http_get/3]).
    
testget :-
    http_get('https://thinknetc3.ddns.net/chita/apigps/api/Tramite/ListarConParametros?Ticket=qwqw', Reply, [request_header('Content-Type'='application/json'),status_code(Code)]),
    atom_json_dict(Reply, Dict, []),
    format('Status code: ~w~n', [Code]),
    format('Reply: ~w~n', [Reply]),
    format('Parsed Dict: ~w~n', [Dict]),
    format('Tramites: ~w~n', [Dict.tramites]).


 testget2 :-
    crearDictJsonTramite(UserID,Tramite,TramiteID,Dict,TopicoRes,Tokeninicio),    


     
