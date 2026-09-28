:- [chatbot].

t :-
    chatbot:mimetype_por_extension('https://thinknetc3.ddns.net/chitaV2/Varios/QRs/263b3396a33d4b43b775e90c19496943.svg', M1),
    writeln(svg: M1),
    chatbot:mimetype_por_extension('https://thinknetc3.ddns.net/chita/PDFs/4d17.pdf', M2),
    writeln(pdf: M2),
    chatbot:mimetype_por_extension('https://x.org/img.PNG', M3),
    writeln(png: M3),
    chatbot:mimetype_por_extension('https://x.org/archivo', M4),
    writeln(default: M4),
    V = [_{'Mensaje':'','Contenido':'https://x/qr.svg','Nombre':'URL_CV'},
         _{'Mensaje':'','Contenido':'','Nombre':'DeepLink'}],
    include(chatbot:variable_con_contenido, V, Validas),
    maplist(chatbot:variable_a_part, Validas, Partes),
    writeln(partes: Partes).
