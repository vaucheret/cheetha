:- module(test_url_asincronico,[main/0]).

:- use_module(library(http/http_client)).

main :-
        catch(
        http_post(
            'http://localhost:8000/notificacion_tramite',
            json(_{ user_id: "5492995301481", tramite_id: "cc4ef2fa-d957-409c-a7fc-fe44f833f9f1" },
		 resultado: _{
				accion : 1,
				topicoKafkaEE : "DATOS_WAP_V2",
				urlKafkaEE : "66.70.179.213:9092",
				tramiteID : "cc4ef2fa-d957-409c-a7fc-fe44f833f9f1",
				topicoKafkaMotor : "--",
				urlKafkaMotor : "66.70.179.213:9092",
				instanciatramite : 174,
				instanciastep : 751,
				variablesPedidas : [
						       _{codigo: 32,
							 label: "Ingrese su CUIT",
							 listaQuery: [],
							 clase: 4},
						       _{codigo: 33,
							 label: "Ingrese su edad",
							 listaQuery: [],
							 clase: 1},
						       _{codigo: 34,
							 label: "Defina su sexo (M: Masculino - F: Femenino)",
							 listaQuery: [],
							 clase: 4}
						   ]
			    }
		),
            _,
            [ request_header('Content-Type'='application/json'),
              timeout(5)
            ]
        ),
        E
	%%%%%%% log %%%%%%%%
        ,format(user_output,"❌ Error enviando mensaje: ~w ~n",[E])
        %%%%%%% log %%%%%%%%
    ).
	
