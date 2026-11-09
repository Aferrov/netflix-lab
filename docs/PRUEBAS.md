# Pruebas automatizadas y CI

El backend usa `node:test` y `node:assert/strict`, incluidos en Node.js 20. No necesita un framework externo ni credenciales AWS para ejecutar las pruebas. `package-lock.json` permite usar el mismo comando `npm ci` localmente y en GitHub Actions.

## Qué se comprueba

| Suite | Casos | Alcance |
|---|---|---|
| Unitarias | 13 | Conversión y errores del contador, validación de trabajo CPU, presentación del estado de pods, modo degradado sin Redis, consultas del HPA y validación del borrado de pods. |
| Integración | 6 | Peticiones HTTP al backend, Redis real compartido por dos instancias, incrementos concurrentes, sondas de salud, estados de fallo, trabajo CPU y respuestas de error. |
| Coordinador AWS | 30 | Selección de parámetros, estados por entorno, roles/IP, orden de operaciones, recuperación de contexto y propagación de fallos con comandos externos simulados. |

Las unitarias sustituyen las dependencias externas con funciones controladas. Las pruebas de integración que comprueban visitas usan el cliente TCP de producción y Redis real: `visits: null` hace fallar esas pruebas, aunque el endpoint responda HTTP 200. Las peticiones HTTP tienen un timeout para evitar esperas indefinidas.

Las llamadas a Kubernetes se prueban con respuestas controladas. Esta suite no demuestra un despliegue real, la recuperación por kubelet, el HPA bajo carga ni el frontend. Esas evidencias se obtienen por separado en el clúster.

## Ejecutar con Docker Compose (sin instalar Node.js)

Desde la raíz del repositorio, con Docker y Compose disponibles:

```bash
LOCAL_UID="$(id -u)" LOCAL_GID="$(id -g)" \
  docker compose -f backend/compose.test.yaml up \
  --abort-on-container-exit --exit-code-from tests
```

Compose crea un Redis dedicado, espera a que esté sano y ejecuta la instalación, comprobación de sintaxis y ambas suites con Node.js 20. Redis no publica puertos en el equipo y no utiliza el Redis de AWS. `--exit-code-from tests` conserva el resultado de las pruebas: `0` significa éxito y un valor distinto significa fallo.

Los reportes se guardan en `backend/reports/`. Después de revisarlos, elimina los contenedores y la red de pruebas:

```bash
docker compose -f backend/compose.test.yaml down --volumes
```

## Ejecutar con Node.js instalado

Requiere Node.js 20 o superior y npm. Los comandos siguientes se ejecutan desde la raíz:

```bash
npm --prefix backend ci
npm --prefix backend run check
npm --prefix backend run test:unit
```

Las unitarias no necesitan Redis. Para integración, inicia un Redis exclusivo de pruebas:

```bash
docker run --detach --rm --name netflix-lab-test-redis \
  -p 127.0.0.1:6380:6379 redis:7-alpine
```

Comprueba que responda `PONG`:

```bash
docker exec netflix-lab-test-redis redis-cli ping
```

Después ejecuta:

```bash
REDIS_HOST=127.0.0.1 REDIS_PORT=6380 \
  npm --prefix backend run test:integration
```

O ejecuta las dos suites en orden:

```bash
REDIS_HOST=127.0.0.1 REDIS_PORT=6380 npm --prefix backend test
```

Al terminar:

```bash
docker stop netflix-lab-test-redis
```

Usa un Redis de pruebas sin otros clientes: la suite comprueba incrementos exactos en la clave `visits`. No ejecuta `FLUSHDB` ni borra datos, pero otro cliente incrementando esa clave interferiría con los resultados.

## Reportes

Cada suite genera los reportes incluso cuando una aserción falla:

```text
backend/reports/
├── unit.xml             # resultados JUnit: casos, fallos y duración
├── unit.txt             # resultados legibles y cobertura unitaria
├── integration.xml      # resultados JUnit de integración
└── integration.txt      # resultados legibles y cobertura de integración
```

La consola y los archivos `.txt` muestran el resultado por prueba y la tabla de cobertura. La cobertura nativa también lista los archivos de pruebas: para analizar la aplicación, revisa la fila de `server.js`. Los porcentajes de ambas suites son independientes; no se suman ni representan una cobertura combinada. No se ha impuesto un umbral mínimo de cobertura.

Los reportes generados están excluidos de Git. En GitHub Actions se conservan como artefactos durante 14 días; descarga los que necesites para el informe antes de que expiren.

## Pipeline GitHub Actions

Archivo: `.github/workflows/terraform-validate.yml`, workflow **CI - tests and Terraform**.

Se ejecuta en Pull Requests, en cambios a `main` y manualmente mediante **Run workflow** (una vez publicado el archivo en la rama predeterminada):

```text
Backend tests
  ├── Node.js 20 + Redis con healthcheck
  ├── npm ci
  ├── comprobación de sintaxis
  ├── pruebas unitarias
  ├── pruebas de integración
  ├── regresiones Python del coordinador de stacks (AWS/Terraform simulados)
  └── subida de reportes (también si falla una prueba)
             │ solo si el job pasa
             ▼
Validación de Terraform: local / AWS platform / AWS application
```

Una prueba fallida devuelve un código distinto de cero, falla el job `Backend tests` y omite los jobs dependientes de Terraform mediante `needs: tests`. La subida de reportes usa `always()` para conservar el diagnóstico. Si la instalación o un paso anterior impide ejecutar una suite, no habrá reporte de esa suite.

Para ver los resultados: **GitHub → Actions → ejecución del workflow → Backend tests**. En **Artifacts**, descarga **backend-test-reports** para obtener los XML y reportes de texto.

Para bloquear también la fusión de un PR, un administrador debe configurar una regla de protección/ruleset de `main` que requiera el check **Backend tests**. Que el workflow falle no activa por sí solo esa protección.

Cuando se añadan jobs de construcción, publicación y despliegue, deberán depender de `tests` y de las validaciones necesarias. Este workflow todavía no publica imágenes ni despliega en AWS.

El despliegue automatizado local está descrito en el [README](../README.md). Las regresiones del coordinador se ejecutan con `python3 -m unittest discover -s scripts/tests -v`; no requieren credenciales AWS y sus resultados aparecen en el log de CI. Los artefactos JUnit/cobertura descritos aquí corresponden al backend.

## Evidencia de que un fallo bloquea el pipeline

1. Crea una rama de prueba y cambia temporalmente una aserción de una unitaria para que espere un resultado incorrecto.
2. Abre un PR y observa que **Backend tests** falla, los jobs de Terraform quedan omitidos y se conserva `unit.xml` con el fallo.
3. Guarda el enlace de la ejecución y el reporte para el informe.
4. Corrige la aserción en esa misma rama. La siguiente ejecución debe pasar las dos suites y las validaciones de Terraform.
5. Conserva también el enlace de la ejecución exitosa; no fusiones el cambio deliberadamente incorrecto.

Estas ejecuciones remotas son parte de la evidencia a recopilar por el equipo. Tener el YAML configurado no demuestra que GitHub Actions ya lo haya ejecutado.

## Cambios de backend para permitir pruebas

`createBackend()` crea un servidor con estado propio y permite sustituir Redis/Kubernetes en unitarias. Importar `server.js` no abre un puerto; ejecutarlo con `node server.js` mantiene el puerto 8080 y el manejo de SIGTERM del contenedor. `REDIS_PORT` es opcional y su valor predeterminado sigue siendo 6379.

Se añadió validación de `ms` en `/api/work`: valores no enteros o negativos devuelven HTTP 400, evitando que un valor no numérico deje el trabajo sin terminar. Se conserva el valor predeterminado de 50 ms y el límite de 1000 ms. El contador rechaza respuestas Redis malformadas o enteros fuera del rango seguro de JavaScript.

## Verificación local realizada

En la comprobación local del 8 de noviembre de 2026 se verificó:

- Node.js 20 y Redis 7 mediante Compose: 13 unitarias y 6 de integración aprobadas, sin casos omitidos.
- XML de ambas suites parseables y sin elementos de fallo en la ejecución final.
- Una aserción incorrecta temporal hizo fallar la suite y quedó registrada en JUnit; el caso temporal se retiró después de la comprobación.
- Un puerto Redis no disponible hizo fallar las pruebas de integración que necesitan el contador real.
- El workflow pasó `actionlint`.
- La imagen Docker del backend se construyó y respondió HTTP 200 en `/healthz` y `/ready` al arrancar con su comando de producción.

También pasaron las 30 regresiones del coordinador, las validaciones de los tres stacks Terraform y ShellCheck de los scripts Bash. Los contenedores locales de verificación se eliminaron. La ejecución remota de GitHub Actions sigue pendiente de evidencia.

Posteriormente se comprobó en AWS una actualización de `prod` que fijó `REDIS_PORT=6379` en el Deployment. La verificación HTTP del coordinador pasó y el contador aumentó en peticiones sucesivas. Consulta el [informe técnico](INFORME_TECNICO.md) para el diagnóstico, la evidencia disponible y los límites de las comprobaciones.
