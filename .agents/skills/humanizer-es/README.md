# Humanizer Español

Un *skill* portátil que edita textos **en español** para que suenen naturales, creíbles y escritos por una persona, no por una IA. Es Markdown puro, así que funciona en cualquier *harness* que cargue skills (Claude Code, OpenCode, Codex y otros).

No es el Humanizer en inglés traducido. Es una adaptación nativa: la taxonomía, los detectores y los ejemplos están rediseñados para los fallos propios del español generado por IA (muletillas, calcos del inglés, nominalización, simetría forzada, tono corporativo, raya al estilo inglés, títulos en mayúsculas a la inglesa) y para sus variantes (España, Latinoamérica, neutro).

## Qué hace

Detecta y corrige las señales típicas de escritura por IA en español, conservando el significado, la intención, los datos, el tono, el registro, la variante y la voz de quien escribe. Trabaja en un bucle **borrador → auditoría → versión final**: escribe una primera versión, se pregunta "¿qué hace que esto todavía suene a IA?" y reescribe para corregirlo.

## Para quién es

- Quien redacta o revisa contenido en español (blogs, webs, correos, documentación, propuestas, marketing, textos académicos).
- Quien usa IA para escribir y quiere que el resultado deje de "sonar a IA".
- Equipos que necesitan respetar una variante (España / Latinoamérica / neutro) y un registro concretos.

## Instalación

### CLI de skills

```bash
npx skills add jaimeberdejo/humanizer-es
```

Actualizar:

```bash
npx skills update humanizer-es
```

Instalar en todos los *harnesses* compatibles:

```bash
npx skills add jaimeberdejo/humanizer-es --agent '*'
```

### Plugin de Claude Code

```
/plugin marketplace add jaimeberdejo/humanizer-es
/plugin install humanizer-es@humanizer-es
```

Se invoca como `/humanizer-es:humanizer-es`.

### Manual

El artefacto en tiempo de ejecución es `SKILL.md`. Cópialo donde tu *harness* espere los skills:

```bash
git clone https://github.com/jaimeberdejo/humanizer-es.git /ruta/a/tus/skills/humanizer-es
```

## Uso

```
/humanizer-es

[pega aquí tu texto]
```

```
Humaniza este texto: [tu texto]
```

Puedes indicar variante, registro e intensidad:

```
Humaniza esto en español de España, registro profesional, intensidad media:
[tu texto]
```

### Calibración de voz

Para que respete tu estilo, pásale una muestra de cómo escribes:

```
/humanizer-es

Esta es una muestra de cómo escribo, para que cojas el tono:
[2-3 párrafos tuyos]

Ahora humaniza este texto:
[texto generado por IA]
```

Analiza tu ritmo de frase, tu vocabulario y tus manías, y los aplica en la reescritura en vez de devolverte un texto "limpio" pero genérico.

## Qué la diferencia del Humanizer en inglés

El original ataca *tells* del inglés (em dash, *title case*, "rule of three", vocabulario tipo *delve* o *tapestry*, comillas curvas). El español falla de otra manera, y este skill lo refleja:

| Tema | Inglés (original) | Español (esta adaptación) |
|------|-------------------|---------------------------|
| Raya / em dash | "Córtalas todas" | La raya **es correcta** en español, pero se ha vuelto una marca de la IA: se **elimina** en la versión final (coma, dos puntos, punto o paréntesis). Única excepción: la raya de diálogo literario. |
| Comillas | Curvas → rectas | Depende de la variante: «latinas» en España editorial, "rectas" en LatAm y web. Coherencia antes que un único tipo. |
| Títulos | *Title Case* → sentence case | Mayúscula **solo** en la primera palabra; el *Título En Mayúsculas* es un tell de texto traducido. |
| Léxico | *delve, tapestry, vibrant* | Muletillas españolas: "es importante destacar", "en este sentido", "sin lugar a dudas", "solución integral". |
| Calcos | (no aplica) | **Categoría nueva:** anglicismos y falsos amigos (*soportar*, *consistente*, *eventualmente*, *librería* por *biblioteca*, *basado en*). |
| Sintaxis | Passive voice | **Nominalización pesada**, cadenas de "que / lo cual" y gerundios de relleno: los vicios reales del español. |
| Variante | (no aplica) | Manejo explícito de España / Latinoamérica / neutro, sin forzar dialecto. |
| Registro | Personalidad vs. neutro | Siete registros con reglas propias (informal, profesional, académico, técnico, marketing, etc.). |

## Variantes admitidas

- **España:** *vosotros*, pretérito compuesto, *ordenador/móvil*, comillas latinas en texto cuidado.
- **Latinoamérica (neutro):** *ustedes*, pretérito simple, *computadora/celular*, sin modismos de un solo país.
- **Internacional neutro (por defecto):** evita a la vez *vosotros* y los regionalismos marcados; vocabulario que se entienda en todas partes.

El skill no fuerza ningún dialecto y nunca mezcla variantes dentro de un mismo texto.

## Modos especiales

- **Modo académico / TFM.** Para TFM, tesis, artículos o documentos universitarios largos, el skill activa un modo defensivo: no inventa ni una afirmación, autor, fuente, limitación ni interpretación; conserva intactas citas, referencias, tablas, ecuaciones y terminología; no fortalece ni debilita los resultados; y humaniza solo la superficie (muletillas, calcos, rigidez) sin tocar la precisión ni la estructura argumental. La intensidad por defecto aquí es suave.
- **Edición de archivos completos.** Al humanizar un documento entero, el skill escribe la versión final limpia en un archivo separado y, si se pide control de calidad, en otro archivo aparte; nunca mezcla las notas del editor dentro del texto, y mantiene secciones, numeración, citas y estructura.

## Patrones detectados

25 patrones en 6 bloques (ver `SKILL.md` para cada uno con ejemplos antes/después):

1. **Léxico** — muletillas de IA · anglicismos y falsos amigos · adjetivos y verbos genéricos · perífrasis para no decir "ser/estar".
2. **Sintaxis y estructura** — nominalización pesada · cadenas de "que / lo cual" · gerundios de relleno · simetría artificial · conectores inflados.
3. **Tono y registro** — tono corporativo vacío · marketing hueco · falsa profundidad · sobreexplicación · atribuciones vagas · registro equivocado.
4. **Estructura del texto** — introducciones de plantilla · cierres moralizantes · ritmo mecánico · encabezados de plantilla.
5. **Puntuación y formato** — raya al estilo inglés · comillas según variante · mayúsculas de título a la inglesa · exceso de negritas/emojis/listas.
6. **Artefactos de IA** — artefactos de chatbot y tono servil · avisos de límite de conocimiento y relleno especulativo.

## Ejemplos

En [`EJEMPLOS.md`](EJEMPLOS.md) hay un conjunto de casos antes/después en distintos registros (de post corporativo a caption de redes), con notas de calidad por caso, una comparación con el Humanizer en inglés y los límites honestos de la skill.

## Decisiones de diseño informadas por la investigación

Antes de adaptar el skill se investigó el problema en español, sin dar por hecho que los patrones del inglés sirvieran. Esto es lo que se encontró y cómo dio forma al diseño.

**Qué se investigó.** Señales de texto en español generado por IA; *translationese* y calcos sintácticos del inglés; falsos amigos frecuentes (*soportar*, *consistente*, *eventualmente*, *actualmente*); recomendaciones de la RAE y Fundéu sobre raya, comillas y mayúsculas; las diferencias España / Latinoamérica / neutro; los manuales de lenguaje claro de varias administraciones; y cómo se percibe la prosa burocrática o "de consultora".

**Problemas propios del español que se encontraron.**
- La raya (—) es legítima en español (incisos y diálogos), pero a fuerza de aparecer en todo lo que genera la IA se ha vuelto una de sus marcas más visibles. Por eso se **elimina** en la versión final aunque esté bien puesta: hoy lee como IA. La única excepción es la raya de diálogo literario, que es estructural y no es donde vive el tell. (Esto coincide con el "córtalas todas" del original inglés, pero por un motivo distinto y con una excepción propia del español.)
- Las comillas no tienen un único "correcto": «latinas» son la norma editorial en España, las "rectas" dominan en LatAm y en la web. La regla útil es coherencia, no un tipo fijo.
- El español tiene fallos sintácticos que el inglés no tiene en la misma medida: **nominalización deverbal** ("la realización de un análisis"), cadenas de **"que / lo cual"** y abuso de **gerundio** (incluido el de posterioridad, que además es incorrecto).
- Las muletillas de IA en español son léxicamente distintas: "es importante destacar", "en este sentido", "sin lugar a dudas", "solución integral", "marcar la diferencia".
- La variante regional es un eje que en el original no existe y que en español es ineludible.

**Ideas del Humanizer en inglés que se conservaron.** La arquitectura general (frontmatter + patrones numerados con antes/después); el bucle borrador → auditoría → versión final; la calibración de voz desde muestras; la sección de personalidad para texto con voz; la guía de falsos positivos y de señales humanas; la regla de "reescribe, no recortes"; el corte de la raya (—), que en español también se ha vuelto un tell; y la idea de buscar *racimos* de tells, no casos sueltos.

**Ideas del original que se reemplazaron.** Las comillas curvas→rectas del original (sustituido por coherencia según variante); el vocabulario AI inglés (*delve*, *tapestry*); y los ejemplos, todos reescritos como texto español nativo, no traducido.

**Categorías nuevas, propias del español.** Anglicismos y falsos amigos; nominalización pesada; cadenas de "que / lo cual"; gerundios de relleno; perífrasis para evitar "ser/estar"; tono corporativo involuntario; manejo de variante (España / LatAm / neutro); y una tabla de siete registros con reglas propias.

**Límites y dudas abiertas.** El "neutro" es una convención, no una variante que nadie hable; el skill lo usa por defecto pero avisa de ello. La frontera entre un anglicismo ya asentado (*software*, *online*) y uno evitable (*soportar*, *librería*) depende del campo y evoluciona. Y, como en el original, la detección funciona mejor con racimos de señales que con tells aislados: aplicado con mano dura, puede aplanar prosa humana legítima.

## Relación con el proyecto original

Adaptación al español de [blader/humanizer](https://github.com/blader/humanizer), que a su vez se basa en [Wikipedia: Signs of AI writing](https://en.wikipedia.org/wiki/Wikipedia:Signs_of_AI_writing) de WikiProject AI Cleanup. Se conserva la licencia MIT y la atribución al autor original.

## Historial de versiones

- **1.2.0** — Tres cambios pensados para documentos académicos largos. (1) Nuevo **Modo académico / TFM**: regla defensiva que prohíbe inventar afirmaciones, autores, fuentes, limitaciones o interpretaciones (incluidos los "añadidos inocentes"), conserva citas, tablas, ecuaciones y terminología, y no fortalece ni debilita los resultados; intensidad suave por defecto. (2) Nueva sección **Edición de archivos completos**: la versión final va limpia en un archivo separado, el control de calidad en otro, y nunca se mezclan notas del editor con el texto. (3) Corregido el ejemplo académico de `EJEMPLOS.md`, que añadía una afirmación ("la bibliografía apenas lo ha documentado") inexistente en el original; ahora no inventa nada y sirve de modelo del modo académico.
- **1.1.0** — Dos cambios. (1) La raya (—) pasa a eliminarse siempre en la versión final, no solo cuando se usa al estilo inglés: se ha vuelto una marca reconocible de la IA y por eso se trata como un tell aunque esté bien puesta. Única excepción: la raya de diálogo literario. (2) Reequilibrio contra el aplanamiento: la skill estaba encuadrada para borrar más que para reescribir, y desinflaba textos. Se añadió un "Principio rector" (sustituir, no vaciar; toque mínimo; la voz manda; ante la duda, editar de menos), una auditoría de dos preguntas, una checklist en dos columnas ("¿quité la marca de IA?" / "¿conservé la calidad?") y se reencuadraron los ejemplos por patrón como quirúrgicos, no como modelo de longitud. Ejemplos de `EJEMPLOS.md` reescritos para conservar peso y voz, y sin inventar datos.
- **1.0.0** — Primera versión de la adaptación al español. Skill reescrito desde cero como `humanizer-es`: 25 patrones en 6 bloques pensados para el español generado por IA, manejo de variantes (España / LatAm / neutro), tabla de registros, niveles de intensidad, calibración de voz, ejemplo completo y lista de control. No es una traducción del original en inglés.

## Licencia

MIT. Ver [LICENSE](LICENSE).
