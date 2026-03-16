 :- module(readenvnorm, [load_env/1]).
    

:- use_module(library(readutil)).

% Carga un archivo .env y registra cada variable
load_env(File) :-
    exists_file(File),
    setup_call_cleanup(
        open(File, read, In),
        process_stream(In),
        close(In)
    ).

process_stream(In) :-
    read_line_to_string(In, Line),
    (   Line == end_of_file
    ->  true
    ;   process_line(Line),
        process_stream(In)
    ).

process_line(Line) :-
    % 1. Limpiar espacios al inicio/final y omitir vacíos o comentarios
    normalize_space(string(Trimmed), Line),
    (   Trimmed == "" ; sub_string(Trimmed, 0, 1, _, "#")
    ) -> true
    ;   % 2. Separar solo por el primer "="
        sub_string(Trimmed, Before, 1, After, "="),
        sub_string(Trimmed, 0, Before, _, KeyString),
        sub_string(Trimmed, _, After, 0, ValString),
        
        % 3. Limpiar la clave y el valor (quitar espacios extra y comillas)
        normalize_space(atom(K), KeyString),
        clean_value(ValString, V),
        
        % 4. Cargar en el entorno del sistema
        setenv(K, V).

% Elimina comillas externas si existen ("valor" o 'valor')
clean_value(Str, Clean) :-
    normalize_space(string(S), Str),
    (   (sub_string(S, 0, 1, _, "\""), sub_string(S, _, 1, 0, "\""))
    ;   (sub_string(S, 0, 1, _, "'"), sub_string(S, _, 1, 0, "'"))
    ) -> sub_string(S, 1, _, 1, Clean)
    ;   Clean = S.
