:- module(formatear_tramites, [reformatear_todos_tramites/0]).

:- use_module(library(http/json)).
:- use_module(library(filesex), [directory_files/2]).
:- use_module(library(lists), [include/3]).

% Predicado principal para reformatear todos los trámites
reformatear_todos_tramites :-
    format("Reformateando archivos JSON en el directorio tramites...~n"),
    
    % Verificar que existe el directorio
    (   exists_directory("tramites") ->
        true
    ;   format("Error: No existe el directorio 'tramites'~n"),
        fail
    ),
    
    % Obtener todos los archivos JSON
    directory_files("tramites", Archivos),
    include(es_archivo_json, Archivos, ArchivosJSON),
    
    % Reformatear cada archivo
    length(ArchivosJSON, Total),
    format("Encontrados ~w archivos JSON~n", [Total]),
    
    maplist(reformatear_archivo, ArchivosJSON),
    
    format("¡~w archivos reformateados exitosamente!~n", [Total]).

% Verificar si un archivo es JSON
es_archivo_json(Archivo) :-
    atom_codes(Archivo, Codes),
    append(_, `.json`, Codes).

% Reformatear un archivo individual
reformatear_archivo(NombreArchivo) :-
    atomic_list_concat(["tramites/", NombreArchivo], RutaCompleta),
    format("Reformateando: ~w~n", [RutaCompleta]),
    
    % Leer el archivo JSON
    catch(
        (
            open(RutaCompleta, read, StreamLectura, [encoding(utf8)]),
            json_read_dict(StreamLectura, Datos),
            close(StreamLectura)
        ),
        Error,
        (
            format("Error leyendo ~w: ~w~n", [RutaCompleta, Error]),
            fail
        )
    ),
    
    % Escribir el archivo con formato bonito
    catch(
        (
            open(RutaCompleta, write, StreamEscritura, [encoding(utf8)]),
            json_write_dict(StreamEscritura, Datos, [width(50), step(4)]),
            close(StreamEscritura)
        ),
        Error2,
        (
            format("Error escribiendo ~w: ~w~n", [RutaCompleta, Error2]),
            fail
        )
    ).

% Predicado para ejecutar desde línea de comandos
main :-
    reformatear_todos_tramites.

% Para ejecutar automáticamente al cargar
:- initialization(main, main).
