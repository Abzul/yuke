# Yuke y Codex: investigación y corrección de la ruta de un turno

Fecha: 4 de octubre de 2026.

## Resumen

Se investigaron errores HTTP 503 que aparecen en yuke, pero no en Codex CLI en la misma máquina. El usuario los observa con frecuencia durante tareas que buscan información en internet y tardan en terminar.

Se encontró una diferencia de compatibilidad: yuke no conservaba ni devolvía la cabecera `x-codex-turn-state`. El cliente oficial de Codex sí usa esa cabecera para mantener la ruta interna durante las solicitudes de un mismo turno.

Se implementó ese mecanismo en yuke. Se añadieron pruebas HTTP y una prueba del motor completo. Se ejecutaron los tests y los benchmarks. Se compiló e instaló la corrección. También se probó el proveedor real con una herramienta local que espera un minuto.

**La corrección está implementada y las pruebas pasan. No se ha demostrado que esta diferencia sea la causa de todos los 503 del usuario. Tampoco se reprodujo la búsqueda concreta que falla.**

## 1. Problema reportado

El mensaje reportado fue:

```text
⚠ the provider returned a server error · HTTP 503 ·
upstream connect error or disconnect/reset before headers.
reset reason: remote connection failure
```

La barra de estado muestra varios intentos, hasta llegar al límite de cinco.

El usuario confirmó lo siguiente:

- El problema también aparece en conversaciones nuevas.
- Ya probó otros modelos y las recomendaciones iniciales.
- Codex CLI funciona en la misma máquina y red.
- El problema se observa con frecuencia al pedir búsquedas web que tardan mucho.

La investigación dejó de tratar la red o una conversación concreta como explicación suficiente. Se revisó la integración de yuke con Codex.

## 2. Entorno revisado

- Código de yuke basado en el commit `45876b1e`.
- Versión instalada antes del cambio: `0.0.1-nightly.20261002+45876b1`.
- Codex CLI instalado: `0.160.0`.
- Proveedor configurado: `openai-codex`, con autenticación OAuth.
- Sin una URL alternativa configurada para ese proveedor.
- Dirección predeterminada:

  ```text
  https://chatgpt.com/backend-api/codex/responses
  ```

Se revisaron el código, la configuración local, el registro y los metadatos de las conversaciones. No se incluyeron credenciales en este informe.

## 3. Qué mostraron los registros

### El 503 no era el tiempo límite local

El registro contenía dos ejecuciones con cinco respuestas HTTP 503 seguidas.

Yuke tiene un límite de espera del proveedor de 300 000 ms, es decir, cinco minutos. Cuando se alcanza ese límite, informa otro error:

```text
the provider stream timed out
```

Por tanto, estos 503 son respuestas del servidor. No son errores producidos por el límite local de cinco minutos.

El texto `upstream connect error ... before headers` indica que el servidor que recibió la solicitud no pudo establecer o mantener una conexión con un servidor interno antes de obtener su respuesta. Esto no descarta que una diferencia en la solicitud del cliente contribuya al fallo.

### Qué significa el contador de cinco intentos

La política existente permite cinco intentos por ronda, sujetos también al presupuesto de reintentos del turno y a otras condiciones de seguridad.

Para un fallo que permite reintentar, las esperas predeterminadas crecen aproximadamente así:

```text
0,5 s → 1 s → 2 s → 4 s
```

Las esperas incluyen una variación aleatoria. El servidor puede pedir una espera mayor mediante sus cabeceras.

El contador no representa cinco minutos. Representa los intentos de la solicitud.

### El corte citado no ocurrió inmediatamente después de una búsqueda

En el corte relacionado con `6658cc8`, la última herramienta fue una edición. La ronda que agotó los cinco intentos duró aproximadamente 20 segundos. La siguiente ejecución también agotó los intentos en un tiempo similar.

Esto muestra que el fallo no es exclusivo de la búsqueda web. No contradice que el usuario lo observe con más frecuencia durante esas tareas.

## 4. Qué se revisó de las herramientas web

El perfil del usuario define `web_search` y `web_fetch` en:

```text
~/.config/yuke/tools/web.js
```

Esas herramientas usan Monid/Tinyfish. No usan la búsqueda nativa de Codex CLI.

El código establece un tiempo límite de 120 segundos por solicitud HTTP a Monid y consulta el estado de los trabajos pendientes. Además, limita el texto que devuelve al modelo.

En el historial se encontró una consulta `web_fetch` que tardó unos 49 segundos y terminó correctamente.

También se comprobó que el motor cierra la respuesta del modelo antes de ejecutar las herramientas. No se encontró evidencia de que la herramienta web mantuviera abierta esa respuesta del modelo hasta alcanzar el límite local.

**No se modificó el plugin web.**

## 5. Diferencias con Codex CLI

Se consultó el código oficial correspondiente a `rust-v0.160.0`, no solo la rama principal.

| Área | Yuke antes del cambio | Codex CLI 0.160.0 |
|---|---|---|
| Transporte del modelo | Solicitudes HTTP POST con respuesta SSE; conexión nueva por solicitud | WebSocket habilitado por defecto para el proveedor OpenAI, con mecanismos de reutilización y alternativa HTTP |
| Continuación | Envía el historial de la solicitud | Puede enviar una continuación incremental por WebSocket |
| Estado de ruta del turno | No conservaba `x-codex-turn-state` | Conserva el primer valor recibido y lo devuelve durante el mismo turno |

El código oficial describe `x-codex-turn-state` como un contrato entre cliente y servidor. Indica que se debe conservar durante el turno, incluidos reintentos y continuaciones. También indica que no se debe reutilizar entre turnos distintos.

Fuentes consultadas:

- [Codex: cliente y estado del turno](https://github.com/openai/codex/blob/rust-v0.160.0/codex-rs/core/src/client.rs)
- [Codex: captura de cabeceras en SSE](https://github.com/openai/codex/blob/rust-v0.160.0/codex-rs/codex-api/src/sse/responses.rs)
- [Codex: solicitudes Responses](https://github.com/openai/codex/blob/rust-v0.160.0/codex-rs/codex-api/src/endpoint/responses.rs)
- [Codex: configuración del proveedor](https://github.com/openai/codex/blob/rust-v0.160.0/codex-rs/model-provider-info/src/lib.rs)

La falta de ese mecanismo era una diferencia comprobada. Su relación causal con los 503 reportados sigue pendiente de confirmar.

## 6. Corrección implementada

### Estado propio de cada turno

Se añadió `CodexTurn` en `lib/ai/route.zig`.

Este estado contiene:

- El allocator del arena que conserva el token durante el turno.
- Un resumen SHA-256 del alcance de la solicitud.
- Una copia propia del primer token recibido.

El motor mantiene ese estado dentro de `Streamer`, que vive durante el turno completo. Los reinicios de los datos de streaming entre rondas no borran el token.

La solicitud de transporte puede tomar prestado ese estado mediante `codex_turn_borrow`. El motor lo conecta solo para el dialecto Responses `codex`.

### Captura y devolución de la cabecera

El transporte HTTP ahora:

1. Conserva el primer `x-codex-turn-state` de una respuesta HTTP 200.
2. Copia sus bytes al arena del turno antes de que el lector invalide las cabeceras de respuesta.
3. Devuelve ese valor en solicitudes posteriores del mismo turno.
4. Lo mantiene al continuar después de una herramienta.
5. Lo mantiene durante reintentos de la misma ruta.
6. No reemplaza el primer token con otro valor recibido más tarde.
7. No captura tokens de respuestas no exitosas, como un 503.

### Separación y seguridad

El estado se vincula a la URL y al conjunto ordenado de cabeceras de la solicitud mediante SHA-256. El cuerpo no forma parte de ese vínculo, porque cambia al continuar la conversación.

Si cambia la URL o alguna cabecera, se descarta el token anterior. Esto incluye cambios de credencial y de cuenta cuando esos datos aparecen en las cabeceras. También cubre cambios de ruta hechos por un hook.

Un turno nuevo empieza sin token.

El transporte rechaza una cabecera `x-codex-turn-state` fijada manualmente cuando gestiona este estado. Así evita enviar un valor estático o duplicado que entre en conflicto con el estado del turno.

El token no se guarda en la base de datos ni en los logs. Las llamadas de compactación no comparten este estado.

### Memoria

Una primera implementación añadía un campo al slot del turno. El benchmark detectó un aumento pequeño de bytes asignados incluso en los turnos sin Codex.

Se cambió esa implementación. El estado final vive en `Streamer`, sin ampliar el slot ni crear un objeto adicional en el heap para cada turno. La copia del token usa el arena que ya pertenece al turno.

En las mediciones finales, las fases del motor sin Codex mantienen el mismo número de asignaciones y los mismos bytes asignados que la base.

## 7. Archivos cambiados

| Archivo | Cambio |
|---|---|
| `lib/ai/route.zig` | Estado `CodexTurn` y referencia prestada desde la solicitud de transporte |
| `lib/ai/transport/http.zig` | Captura y devolución de la cabecera; validación y pruebas HTTP |
| `src/engine/turn.zig` | Estado durante el turno y conexión con las solicitudes Codex |
| `src/engine/Engine.zig` | Registro del nuevo archivo de pruebas |
| `src/engine/codex_turn_test.zig` | Nueva prueba del motor con servidor HTTP local, herramienta, 503, reintento y turno nuevo |
| `docs/providers.md` | Documentación del estado de ruta y sus límites |

No se cambió la API pública de JavaScript. No se modificaron archivos generados.

## 8. Pruebas

### Prueba HTTP del transporte

Se verificó lo siguiente con un servidor local:

- Un token recibido en un 503 no se conserva.
- El primer token recibido en un 200 se conserva.
- Una respuesta posterior no reemplaza ese primer token.
- Se envía una sola cabecera de estado de ruta.
- Un cambio de credencial descarta el estado anterior.
- Un cambio de URL descarta el estado anterior.
- Un estado de turno nuevo no envía el token del turno anterior.

### Prueba del motor completo

La secuencia probada fue:

```text
Solicitud inicial sin token
  → HTTP 200 con token turn-A y llamada a web_search
  → ejecución de la herramienta
  → siguiente solicitud con turn-A
  → HTTP 503
  → reintento con turn-A
  → HTTP 200 y fin del turno
  → nuevo turno sin el token anterior
```

Esta prueba usa el transporte HTTP real de yuke, el motor, el almacenamiento y la ejecución de herramientas. El proveedor es un servidor local controlado.

### Suite completa

Durante el desarrollo se ejecutó:

```sh
mise exec -- zig build test --seed 0
```

La verificación final se ejecutó sin fijar la semilla:

```sh
mise exec -- zig build test --summary all
```

Resultado final:

```text
51/51 pasos completados
1233/1234 tests aprobados
1 test omitido
```

También pasaron `git diff --check` y la comprobación de formato con `zig fmt --check`.

Durante el desarrollo hubo un error de compilación por un error set demasiado amplio y un fallo de la nueva prueba por asumir el orden incorrecto del historial. Ambos se corrigieron antes de la verificación final. No quedaron fallos en la suite final.

## 9. Rendimiento

Se ejecutó el benchmark completo contra la base, con compilación `ReleaseFast`. Se hizo otra ejecución con `-Dmetrics=true` para las métricas de memoria.

```sh
mise exec -- zig build bench -Doptimize=ReleaseFast -- \
  --fixture bench/transcript-fixture.json

mise exec -- zig build bench -Doptimize=ReleaseFast -Dmetrics=true -- \
  --fixture bench/transcript-fixture.json
```

Además, se compararon binarios de base y corregido de forma alternada. Se hicieron cinco ejecuciones por lado y fase, con 3000 iteraciones. Cada ejecución produce cinco repeticiones. Se comparó el cuartil inferior de las 25 medianas por lado.

| Fase | Base | Corregido | Diferencia |
|---|---:|---:|---:|
| `engine_run` | 463 000 ns | 463 583 ns | +0,13 % |
| `engine_images` | 1 610 958 ns | 1 587 917 ns | −1,43 % |
| `stream_native` | 191 708 ns | 191 875 ns | +0,09 % |

Estas diferencias de tiempo están dentro del ruido de medición. No prueban una mejora o una regresión real.

Las métricas finales del motor mantuvieron el número de asignaciones, los bytes asignados y la memoria viva. Los picos también coincidieron en `engine_run` y `engine_images`. El pico de `engine_parallel` varió entre ejecuciones concurrentes, por lo que no se afirma igualdad de ese pico.

No se ejecutó Callgrind: `valgrind` no estaba disponible en este entorno macOS. Estas mediciones tampoco cuantifican el coste del nuevo mecanismo en una conversación Codex real; los benchmarks del motor usan otro protocolo.

## 10. Instalación

Se compiló e instaló el árbol corregido con:

```sh
mise exec -- sh tools/install.sh
```

El script compila en `ReleaseFast` e instala el ejecutable y los archivos de biblioteca. También actualiza los enlaces de tipos del perfil y el enlace del skill de yuke.

Ejecutable instalado:

```text
~/.local/bin/yuke
```

Versión comprobada después de instalar:

```text
yuke 0.0.1-dev
```

**Hay que cerrar y volver a abrir yuke para ejecutar esta compilación.** Un proceso abierto antes de la instalación sigue usando el binario anterior.

Al terminar la implementación inicial, los cambios quedaron en el árbol de trabajo, sin commit ni publicación de una versión. Después, el usuario pidió un fork para revisar el código.

El fork de revisión es [Abzul/yuke](https://github.com/Abzul/yuke). La rama destinada a esta entrega es [`fix/codex-turn-routing`](https://github.com/Abzul/yuke/tree/fix/codex-turn-routing). La entrega incluye el código, el nuevo archivo `src/engine/codex_turn_test.zig` y este informe. No es una publicación oficial del proyecto original.

## 11. Prueba con el proveedor real

Se usó la compilación instalada con `openai-codex/gpt-6.1-sol`, razonamiento `medium` y un perfil temporal aislado.

Ese perfil ofrecía solo una herramienta de prueba llamada `web_search`. La herramienta esperó 60 segundos y devolvió `OK`. **No hizo una búsqueda real en internet ni llamó a Monid/Tinyfish.**

La prueba usó una copia temporal del token de acceso existente, sin copiar el token de renovación. No se intentó renovar la credencial original. La configuración, los datos y el registro de la prueba quedaron en un directorio temporal que se eliminó al terminar.

Resultado:

```text
Código de salida: 0
Duración total: 66,26 segundos
Herramienta: web_search
Estado de la herramienta: completed
Duración de la herramienta: 60 001 ms
Respuesta final: OK
Resultado del turno: turn
```

Esto confirma que la compilación instalada puede continuar con el proveedor real después de una herramienta que espera un minuto. No demuestra que el fallo original haya desaparecido.

Las conversaciones, las credenciales y el código del perfil original no se modificaron. La instalación sí actualizó los enlaces de tipos y del skill que gestiona el instalador.

## 12. Qué no se cambió y qué falta confirmar

No se implementó WebSocket ni el envío incremental de continuaciones. Yuke sigue usando HTTP POST y SSE para estas solicitudes.

No se aumentó el tiempo límite. No se aumentó el número de reintentos. No se cambió el modelo, la URL del proveedor ni el plugin web del usuario.

No se añadió registro nuevo de duraciones por intento, cabeceras de ruta o identificadores de solicitud. Se corrigió el mecanismo de ruta y se verificó con pruebas.

La cabecera conserva la afinidad de ruta que pide el servidor. No obliga al servidor a estar disponible, no permite elegir un servidor sano y no elimina todas las causas posibles de un 503.

**La causa exacta de los fallos reportados sigue pendiente de confirmar.** Si reaparecen después de reiniciar con esta compilación, el siguiente paso es capturar tiempos y metadatos seguros de las solicitudes fallidas, sin credenciales ni contenido privado, y comparar el comportamiento con Codex CLI.

## Conclusión

Se corrigió una diferencia concreta entre yuke y Codex CLI: la conservación del estado de ruta durante un turno. La corrección está probada e instalada. Una prueba aislada con el proveedor real y una herramienta que espera un minuto terminó correctamente.

La confirmación pendiente es comprobar si esta corrección elimina los 503 que el usuario encuentra en su uso habitual.
