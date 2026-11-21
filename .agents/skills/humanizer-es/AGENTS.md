# AGENTS.md

Guía para agentes de IA (Claude Code, Codex, Warp, etc.) que trabajen en este repositorio.

## Qué es este repo

Un *skill* portátil escrito íntegramente en Markdown. El artefacto en tiempo de ejecución es `SKILL.md`: el agente lee su *frontmatter* YAML (metadatos + herramientas permitidas) y luego el *prompt* del editor. No hay build ni código que ejecutar, y la documentación debe evitar atarse a uno o dos *harnesses*.

**Importante: esto NO es un proyecto de traducción.** Es `humanizer-es`, una adaptación **nativa al español** del Humanizer en inglés ([blader/humanizer](https://github.com/blader/humanizer)). Conserva la arquitectura del original (frontmatter + patrones numerados con ejemplos antes/después, bucle borrador → auditoría → versión final, calibración de voz), pero el contenido lingüístico está rediseñado para los fallos propios del español. No traduzcas reglas pensadas para el inglés: el español falla de otra forma.

## Archivos clave

- `SKILL.md` — el skill. *Frontmatter* YAML (`name`, `version`, `description`, `compatibility`, `allowed-tools`) seguido de la lista numerada de patrones. **Es la fuente de la verdad.**
- `README.md` — para personas: instalación, uso, qué la diferencia del original, variantes, patrones y las decisiones de diseño informadas por la investigación.
- `EJEMPLOS.md` — casos antes/después en varios registros, con notas de calidad, comparación con el original inglés y límites honestos. Sirve también como regresión cualitativa al tocar la skill.
- `.claude-plugin/plugin.json` — manifiesto del plugin de Claude Code.
- `.claude-plugin/marketplace.json` — entrada de *marketplace* de un solo repo.
- `LICENSE` — MIT. Conserva la atribución al autor original; este repo es una obra derivada.

## El contrato de mantenimiento

`SKILL.md` y `README.md` deben ir sincronizados. Cuando cambies contenido o comportamiento:

- **Patrones:** el skill define **25 patrones numerados en 6 bloques**. Si añades, quitas o renumeras alguno, actualiza en el mismo cambio la lista de patrones del README y cualquier referencia cruzada. Mantén estable la numeración salvo que renumeres a propósito.
- **Versión:** hay un campo `version:` en el *frontmatter* de `SKILL.md`, una sección "Historial de versiones" en `README.md` y un `version` en `.claude-plugin/plugin.json`. Súbelos juntos. (`marketplace.json` omite la versión a propósito para que `plugin.json` sea la fuente.)
- **Compatibilidad:** mantén el lenguaje de instalación y uso neutro respecto al *harness*. El skill funciona en cualquiera que cargue instrucciones Markdown.
- **Arreglos no obvios:** si cambias el *prompt* para resolver un fallo concreto (una mala edición repetida, un cambio de tono inesperado), añade una nota breve al historial del README explicando qué se arregló y por qué.

## Reglas lingüísticas que hay que mantener a propósito

- **Las reglas del español son intencionadas.** Por ejemplo: la raya (—) es correcta en español, pero se ha vuelto una marca reconocible de la IA, así que la versión final la elimina igualmente (coma, dos puntos, punto o paréntesis). La única excepción es la raya de diálogo literario. No la reintroduzcas como "uso correcto": aquí se decidió tratarla como tell a propósito.
- **Los ejemplos deben ser español nativo,** no traducciones. Si un antes/después suena a inglés traducido, está mal aunque ilustre el patrón.
- **Las suposiciones regionales deben ser explícitas.** España, Latinoamérica y neutro se tratan por separado; el neutro es el valor por defecto cuando no se especifica. Nunca mezcles variantes dentro de un mismo texto ni fuerces *vosotros*, *ustedes* o modismos locales sin que se pidan.
- **Preservar significado por encima de "sonar mejor".** El skill nunca debe inventar datos, cifras, citas ni ejemplos, ni cambiar la postura o el registro del autor. Si editas el *prompt*, no debilites estas reglas de preservación.
- **El "Modo académico / TFM" y la "Edición de archivos completos" son defensivos a propósito.** No los suavices. El primero prohíbe inventar afirmaciones o limitaciones (incluidos los "añadidos inocentes") y conservar citas, tablas y terminología; el segundo evita mezclar notas del editor con el texto final. Los ejemplos de `EJEMPLOS.md` no deben añadir ninguna afirmación que no esté en el "antes"; el caso académico es el modelo a seguir.

## Editar SKILL.md

- Conserva el *frontmatter* YAML válido (formato e indentación).
- El cuerpo es el producto. Edítalo como un documento de instrucciones cuidado, no como código.
- Escribe el skill en español (los metadatos técnicos pueden ir en inglés). Y aplícate el propio skill: que las instrucciones no caigan en las muletillas que el skill enseña a quitar.
