# Cilium — fuera de ArgoCD, a propósito

Este directorio no tiene `application.yaml`. Es la única pieza de `infrastructure/` que ArgoCD
no gestiona, y no es un descuido.

## La frontera

> **Lo que el cluster necesita para existir lo pone Ansible. Lo que vive dentro lo pone Argo.**

Cilium está del lado de Ansible ([`ansible/roles/cilium/`](../../../ansible/roles/cilium/)), que
lo instala por Helm con este mismo `values.yaml`.

## Por qué

**Paradoja de bootstrap.** `playbooks/cluster.yml` tiene que dejar un cluster funcional *antes* de
que ArgoCD exista. Si Argo fuera dueño del CNI, una reconstrucción desde cero no tendría red
hasta que Argo arrancara — y Argo no arranca sin red. Los pods se quedarían en
`ContainerCreating` esperando a un controlador que espera a la red que ese controlador debía
instalar.

**Dos dueños peleando.** El rol de Ansible ejecuta `helm upgrade` en cada pasada del playbook. Con
Argo gestionando el mismo release, cada `ansible-playbook` provocaría un `OutOfSync` y cada
`selfHeal` deshacería a Ansible. El conflicto no daría un error claro: daría reinicios del CNI a
intervalos aleatorios, que es de las cosas más caras de depurar en este cluster.

**El radio de explosión.** `prune` sobre el CNI significa que un error de rutas en Git tumba la red
de los tres nodos a la vez, incluido el propio ArgoCD que tendría que arreglarlo.

## Qué sigue siendo cierto

`values.yaml` continúa siendo la única fuente de configuración de Cilium y sigue versionado. Lo
que cambia es quién lo aplica, no dónde vive. El día que Cilium pase a Argo, el archivo no se
mueve: solo aparece un `application.yaml` al lado y desaparece la tarea de Helm del rol.
