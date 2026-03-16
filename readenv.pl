:- module(readenv, [load_dot_env/1]).

load_dot_env(File) :-
    exists_file(File),
    setup_call_cleanup(
        open(File, read, Stream),
        read_lines(Stream),
        close(Stream)
    ).

read_lines(Stream) :-
    read_line_to_string(Stream, Line),
    (   Line == end_of_file
    ->  true
    ;   process_line(Line),
        read_lines(Stream)
    ).

process_line(Line) :-
    % Ignorar comentarios o líneas vacías
    (   sub_string(Line, 0, 1, _, "#") ; Line == "" ) -> true
    ;   split_string(Line, "=", "", [Key, Value]),
        setenv(Key, Value).
