# Fase 4 — Resumen de ejecución y lecciones

Notas de la sesión del **2026-08-28**, en la que se ejecutaron los pasos 4.1 a 4.9. Este documento
no sustituye a [`BITACORA.md`](BITACORA.md) — allí está el registro formal de decisiones e
incidencias. Aquí queda la lectura en frío: qué salió, qué habría descarrilado a alguien sin
experiencia y qué criterios llevaron a decidir como se decidió.

---

## 1. Resumen de ejecución

### Puntos destacables

| Qué | Resultado |
|---|---|
| Kubernetes | v1.35.8 sobre containerd 1.7.24, `SystemdCgroup = true` |
| CNI | Cilium 1.20.1 por Helm, modo slim, Hubble apagado |
| Reservas | Worker 1974 → **1524 MiB** allocatable · CP 3922 → **2922 MiB** |
| Red verificada | Ping pod↔pod entre nodos distintos (0 % pérdida), CoreDNS, DNS externo |
| NetworkPolicy | `deny-all` corta de verdad: 100 % pérdida, y 0 % al borrarla |
| Snapshot | `cluster-limpio` en 101/102/103, con las VMs apagadas |

La comprobación que más vale es la última fila: es la que justifica haber descartado Flannel. Con
Flannel esa policy se habría aceptado y **ignorado en silencio**, y cada ejercicio de
NetworkPolicy del CKA habría dado un falso positivo.

### Decisiones tomadas, y por qué

**Kubernetes v1.35 en lugar de la v1.34 del roadmap.** El CKA está hoy sobre v1.35. Como además
v1.36 y v1.37 ya están publicadas, el escenario 10 de la Fase 9 (`kubeadm upgrade`) se practica de
verdad en vez de servir para ponerse al día.

**Cilium por Helm con `values.yaml` versionado, no `cilium install`.** La configuración vive en
`gitops/infrastructure/cilium/values.yaml`, que la Fase 5 adopta como Application de ArgoCD sin
reescribir nada. Un comando suelto habría que recordarlo y traducirlo después.

**`kubeadm init --config` en vez de una fila de flags.** Los flags no se pueden parchear ni
releer, y este cluster se va a reconstruir muchas veces.

**Las reservas del kubelet no se editan a mano.** Aquí se tomó distancia del roadmap a propósito:
`/var/lib/kubelet/config.yaml` lo regenera kubeadm en cada `upgrade`, así que esa edición se
habría perdido justo en el escenario 10 de la Fase 9 — y sin avisar. Las de worker van en el
`KubeletConfiguration` del config (→ ConfigMap del cluster) y las del control plane como patch
reaplicable.

### Riesgos y hallazgos

**El más serio: `nodeRegistration.patches` no existe en la API `v1beta4`** — es de `v1beta3`. Lo
peligroso no es el error, es que kubeadm lo degrada a un warning perdido entre la salida y **crea
el cluster igual, sin aplicar el patch**. El control plane habría quedado con reservas de worker y
ninguna señal de ello. Se detectó porque se verificó el resultado del `--dry-run`, no sólo que
terminara bien. En kubeadm, un campo mal colocado es un warning, no un fallo.

**Dos defaults del containerd de Debian que rompen o degradan el cluster:**

- `bin_dir = /usr/lib/cni`, un directorio **vacío**, mientras Cilium instala en `/opt/cni/bin`.
  Dejó CoreDNS clavado en `ContainerCreating` (`failed to find plugin "loopback"`). Corregido en
  los tres nodos.
- `sandbox_image = pause:3.8` frente a `pause:3.10.1`. Este no rompe nada visible, y por eso es
  peor: el kubelet sólo protege del garbage collector la `pause` que él conoce, así que puede
  borrar la que containerd usa y tumbar pods sin causa aparente.

Ambos son específicos de instalar containerd desde los repos de Debian. Con el paquete de Docker
no aparecen.

**Margen de recursos:** thin pool al 20 % de 66,87 GB y 6 de 15 GB de RAM en uso. Holgado, pero
los snapshots de la Fase 9 salen del mismo pool.

### Lo que conviene saber para operar este cluster

- **`export KUBECONFIG=~/.kube/config-homelab`** — no está en `~/.kube/config` para no pisar otros
  contextos.
- **Los certificados caducan el 29 de agosto de 2027** (364 días). `kubeadm certs check-expiration`.
- **Al hacer `kubeadm upgrade`, pasar `--patches /etc/kubernetes/patches`.** Si se omite, el
  control plane pierde sus reservas silenciosamente. Es el mismo fallo de arriba por otra puerta.
- **Tras un arranque de las VMs, los pods pasan por `Unknown` unos segundos** mientras el kubelet
  vuelve a reportar. Es normal; se recomponen solos.
- **Ante comportamiento raro, sospechar de la memoria antes que de la red.** Con 1524 MiB
  allocatable por worker, el OOM killer produce síntomas que parecen de conectividad.
- **Rollback:** `qm rollback <101|102|103> cluster-limpio`. Y si algo se tuerce antes de eso,
  `tofu destroy && tofu apply` reconstruye las VMs en 48 s.

---

## 2. Dónde se habría atascado alguien sin experiencia

Ordenado por coste real, que no coincide con la dificultad aparente. La regla que lo explica casi
todo: **lo que falla ruidoso es barato; lo que falla en silencio se paga días después, cuando ya
nadie relaciona el síntoma con la causa.**

### Los tres fallos silenciosos — los caros

**1. El patch de kubeadm que se ignora sin error.**
`patches:` bajo `nodeRegistration` es donde va en la API `v1beta3`. En `v1beta4` va en la raíz.
kubeadm no falla: emite `strict decoding error: unknown field` como *warning*, lo entierra entre
cien líneas de salida del `init` y **crea el cluster igual**, sin aplicar el patch.

Alguien sin experiencia habría visto `Your Kubernetes control-plane has initialized
successfully!`, tres nodos `Ready`, y habría seguido adelante. El control plane se habría quedado
con reservas de worker. ¿Cuándo se descubre? Meses después, cuando bajo presión de memoria el OOM
killer mata al kubelet del control plane y todo el cluster parece caerse por la red. Depurar eso
desde el síntoma son horas, y probablemente por el camino equivocado.

Lo que lo destapó: hacer `--dry-run` **y leer el archivo que genera**, no conformarse con que
terminara bien. La diferencia entre "el comando no dio error" y "el resultado es el que quería" es
exactamente lo que separa esto de un fallo latente.

**2. `sandbox_image = pause:3.8` cuando kubeadm espera `3.10.1`.**
Este ni siquiera produce un warning. El cluster funciona perfectamente. El problema aparece
semanas más tarde: el garbage collector del kubelet sólo protege la imagen `pause` que él conoce,
así que puede borrar la que containerd está usando de verdad, y a partir de ahí mueren pods sin
causa aparente y sin patrón. Es de los síntomas más desorientadores que existen porque no
correlaciona con nada — ni con carga, ni con despliegues, ni con hora del día.

Sólo se detecta si a alguien se le ocurre comparar `kubeadm config images list` con lo que tiene
containerd configurado. No es un paso que aparezca en ninguna guía.

**3. Las reservas del kubelet editadas a mano.**
El roadmap decía editar `/var/lib/kubelet/config.yaml`. Funciona hoy. Pero kubeadm regenera ese
archivo en cada `upgrade`, así que las reservas desaparecen justo en el escenario 10 de la Fase 9
— y en silencio. El cluster sigue arrancando; sólo pierde la protección contra OOM en el momento
de mayor cambio, que es cuando menos se va a sospechar de eso.

Aquí el error de principiante no es técnico, es de criterio: **hacer lo que dice la guía sin
preguntarse quién más escribe en ese archivo.**

### Los ruidosos — baratos, pero desorientadores

**CoreDNS clavado en `ContainerCreating`.** El containerd de Debian busca los plugins CNI en
`/usr/lib/cni`; Cilium los instala en `/opt/cni/bin`. El directorio de Debian estaba vacío.

Aquí la trampa no es encontrar la causa, es **dónde se busca**. El síntoma es "el DNS del cluster
no arranca", y el instinto lleva a depurar CoreDNS o Cilium: mirar sus logs, reinstalar el CNI,
buscar en foros "coredns ContainerCreating cilium". Se pueden ir horas ahí. La causa estaba en
`kubectl describe pod`, en una línea que dice literalmente `failed to find plugin "loopback" in
path [/usr/lib/cni]` — y `loopback` no es de Cilium, es un plugin base. Ese detalle es la pista:
si falta hasta `loopback`, el problema no es el CNI que instalaste, es **dónde mira containerd**.

Lección transferible: cuando falla algo que no instalaste tú, el problema casi nunca está en lo
que sí instalaste.

**`sysctl: command not found` al verificar por SSH.** Está en `/usr/sbin`, fuera del PATH del
usuario `debian`. Alguien sin experiencia concluye que el sysctl no se aplicó, vuelve atrás y
rehace un paso que estaba **bien**. Es el peor tipo de fallo de verificación: te hace desandar
trabajo correcto.

**`---` de más en el YAML.** Las líneas de comentario iniciales más el separador forman un primer
documento vacío, y kubeadm responde `kind and apiVersion is mandatory`. El mensaje no dice
*dónde*, así que se revisa el `apiVersion` del bloque que sí lo tiene. Barato una vez que se sabe;
frustrante la primera vez.

### Lo que no llegó a pasar porque se decidió antes

Estas no aparecen en la bitácora como incidencias precisamente porque se evitaron:

- **Instalar v1.34 porque lo decía el roadmap.** Habría supuesto estudiar sobre una versión
  anterior a la del examen, y el `kubeadm upgrade` de la Fase 9 se habría gastado en ponerse al
  día en vez de en practicar. El roadmap no estaba mal — estaba *fechado*. Verificar contra la
  fuente (la página del CKA) costó un minuto.
- **`cilium install` en vez de Helm.** Funciona igual de bien hoy. El coste llega en la Fase 5,
  cuando ArgoCD necesita esa configuración declarada y hay que reconstruirla de memoria a partir
  de un comando que ya nadie recuerda.
- **`ballooning` activado** (Fase 3): el kubelet calcula su capacidad al arrancar y nunca se entera
  de que el hipervisor le quitó RAM. Sigue programando pods hasta el OOM.
- **`ping` como prueba de conectividad** (Fase 3): el ping pasaba mientras el TCP al 8006 daba
  `no route to host`. Un `plan` limpio tampoco probaba nada, porque con el state vacío no consulta
  la API.

### Los criterios que guiaron las decisiones

Cuatro, y son transferibles fuera de Kubernetes:

**Verificar el resultado, no el código de salida.** Es el que salvó el patch de kubeadm y el que
confirmó que el cifrado del state era real. "Terminó sin error" y "hizo lo que quería" son
afirmaciones distintas.

**Preguntar quién más escribe en este archivo.** Decide entre editar `/var/lib/kubelet/config.yaml`
(lo pisa kubeadm) y usar patches. Mismo criterio que llevó a poner los límites de Cilium en un
`values.yaml`.

**Comprobar el terreno antes de escribir.** Media hora de verificaciones — versiones publicadas,
versión del examen, qué trae containerd de Debian, si hay swap, si `python3` existe — decidió tres
cosas importantes antes de teclear nada. Es el mismo patrón que ya había funcionado en la Fase 3 y
que ahí evitó un thin pool sobreaprovisionado.

**Distinguir "el roadmap dice X" de "X es correcto hoy".** El roadmap es un punto de partida
escrito en un momento concreto. Provider 45 versiones por detrás, `VM.Monitor` eliminado, v1.34
desactualizada, reservas por una vía que no sobrevive al upgrade: cuatro desviaciones en dos
fases. Ninguna era un error de quien lo escribió.

Y una honesta sobre el método: **de las tres cosas que fallaron en silencio, dos se detectaron por
verificar y una por leer el mensaje entero en vez del titular.** No hubo intuición; hubo
comprobación. Es la parte reproducible del oficio.
