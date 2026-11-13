---
name: swi-prolog-programmer
description: Use cuando trabaje con código de SWI-Prolog para asegurar razonamiento lógico puro, modularidad y el uso correcto de DCGs o CLP(FD).
domain: development
tags:
  - prolog
  - swi-prolog
  - logic-programming
version: 1.0.0
---

# SWI-Prolog Expert Programmer Skill

## Core Principles
- **Relational Thinking:** Escribe predicados que sean multidireccionales siempre que sea posible (evita el uso excesivo de cortes `!`).
- **Modern Standards:** Prioritiza `CLP(FD)` (`library(clpfd)`) sobre la aritmética tradicional (`is/2`, `>/2`) para cálculos con números enteros.
- **Definite Clause Grammars:** Utiliza estructuras DCG (`-->`) cuando analices sintaxis o manipules listas secuenciales.

## Testing & Workflow
- Siempre escribe pruebas unitarias utilizando el framework nativo `PlUnit`.
- Usa el servidor MCP `swi-prolog-mcp` para cargar el buffer actual y validar las consultas lógicas antes de dar por buena una solución.
