# TP — Cassandra Reaper : Réparation centralisée du cluster

> **Contexte** : Cluster Cassandra (`archivage-db`) de 2 noeuds dans 1 datacenter (`ccu`),
> 1 rack (`rack1`), monitoré par Prometheus + Grafana.
> Ce TP ajoute un service **Reaper** centralisé et guide sa mise en œuvre complète.

---

## Table des matières

1. [Rappels théoriques](#1-rappels-théoriques)
2. [Architecture cible](#2-architecture-cible)
3. [Prérequis](#3-prérequis)
4. [Intégration de Reaper dans docker-compose.yml](#4-intégration-de-reaper-dans-docker-composeyml)
5. [Création du keyspace de backend Reaper](#5-création-du-keyspace-de-backend-reaper)
6. [Démarrage et vérification](#6-démarrage-et-vérification)
7. [Prise en main de l'interface web](#7-prise-en-main-de-linterface-web)
8. [Lancer une réparation manuelle](#8-lancer-une-réparation-manuelle)
9. [Planifier des réparations automatiques](#9-planifier-des-réparations-automatiques)
10. [Surveiller les réparations dans Grafana](#10-surveiller-les-réparations-dans-grafana)
11. [Scénarios avancés](#11-scénarios-avancés)
12. [Nettoyage](#12-nettoyage)
13. [Questions de validation](#13-questions-de-validation)

---

## 1. Rappels théoriques

### Pourquoi réparer dans Cassandra ?

Cassandra utilise un modèle d'**écriture distribuée** sans coordination forte.
Au fil du temps, des **inconsistances** peuvent apparaître entre réplicas à cause de :

| Cause | Explication |
|---|---|
| Nœud temporairement hors ligne | Il manque des mutations reçues pendant son absence (*hinted handoff* limité dans le temps) |
| Suppression (*tombstone*) expirée | Un réplica peut « ressusciter » une donnée supprimée (`gc_grace_seconds` dépassé) |
| Bug réseau ou matériel | Paquets perdus silencieusement |
| Compaction asymétrique | Les données peuvent diverger sur le disque |

La **réparation anti-entropie** (`nodetool repair`) force la synchronisation entre réplicas via
un protocole **Merkle Tree** : chaque nœud calcule une empreinte de ses données et les compare
avec ses voisins ; les différences sont réconciliées.

### Pourquoi Reaper ?

`nodetool repair` lancé manuellement est :
- **dangereux** si mal planifié (surcharge du cluster)
- **limité** : un seul nœud à la fois, pas de suivi, pas d'interface
- **difficile à orchestrer** sur plusieurs DC

**Cassandra Reaper** (projet open-source de Spotify / The Last Pickle) apporte :

- Interface web intuitive
- Planification par cron
- Réparations **segmentées** pour limiter l'impact
- Gestion multi-datacenter et multi-cluster
- Persistence de l'état dans Cassandra lui-même (`cassandra` backend)
- Métriques Prometheus natives

---

## 2. Architecture cible

```
┌────────────────────────────────────────────────────────────────────┐
│                      cassandra_network (10.17.64.0/24)             │
│  Cluster : archivage-db                                            │
│  DC: ccu                                                           │
│  Rack: rack1                                                       │
│  ┌──────────────────────┐                                          │
│  │  cassandra01         │                                          │
│  │  10.17.64.5  seed ●  │                                          │
│  └────────┬─────────────┘                                          │
│           │                                                        │
│  ┌──────────────────────┐                                          │
│  │  cassandra03         │                                          │
│  │  10.17.64.6  seed ●  │                                          │
│  └──────────────────────┘                                          │
│                                                                    │
│  ┌─────────────────────────────────────────────────────┐           │
│  │  reaper  (.175)   :8080 (UI)  :8081 (admin)         │           │
│  │  → JMX vers cassandra01..02  (:7199)                │           │
│  │  → Backend : keyspace reaper_db dans le cluster     │           │
│  └─────────────────────────────────────────────────────┘           │
│                                                                    │
│  prometheus (.170)   grafana (.171)   exporters (.161-.162)        │
└────────────────────────────────────────────────────────────────────┘
```

---

## 3. Prérequis

### 3.1 Vérifier que le cluster est opérationnel

Cluster Cassandra déployé via Docker Compose 

Cassandra 4.1.11 : Cluster 2 nœuds sur le rack1 dans le DC 'ccu'


#### 1°) Démarrage du cluster

#### Étape 1 : Préparation de l'environnement

```bash
cd ~
# A ne pas faire en production évidemment : 
sudo systemctl stop apparmor
sudo systemctl stop ufw
sudo systemctl disable apparmor
sudo systemctl disable ufw
```

```bash
cd ~
sudo rm -Rf ~/cassandra-reaper
```

#### Ici, on va simplement cloner le projet :
```bash
git clone https://github.com/crystalloide/cassandra-reaper

cd ~/cassandra-reaper
```
#### Vérifier le contenu ou créer le fichier docker compose de notre cluster 4 noeuds cassandra :
```bash
cat Cluster_2_noeuds_1_rack_1_DC_Prometheus_Grafana.yml
```

#### 2°) Créer les répertoires de volumes :
```bash
sudo rm -Rf ~/cassandra-reaper/docker/cassandra*
mkdir -p ~/cassandra-reaper/docker/cassandra01 ~/cassandra-reaper/docker/cassandra02 
```
```bash
mkdir -p ~/cassandra-reaper/docker/cassandra01-conf ~/cassandra-reaper/docker/cassandra02-conf
```
#### On affiche les répertoires créés :
```bash
ls ~/cassandra-reaper/docker
```
##### Affichage : 
```bash
     cassandra01       cassandra02       
     cassandra01-conf  cassandra02-conf 
```

#### 3°) Démarrage du cluster avec Docker Compose

```bash
# Démarrer le cluster en arrière-plan
docker compose -f Cluster_2_noeuds_1_rack_1_DC_Prometheus_Grafana.yml up  -d
```
#### Suivre les logs pour vérifier le démarrage (dans un autre terminal si besoin)
```bash
cd ~/cassandra-reaper
docker compose -f Cluster_2_noeuds_1_rack_1_DC_Prometheus_Grafana.yml logs
```

#### Dans un autre terminal, pour suivre  :
```bash
cd ~
docker ps -a 
```
#### Affichage (exemple) ': 
```bash
# 
# CONTAINER ID   IMAGE              COMMAND                  CREATED              STATUS                             PORTS                                                                                                                                                       NAMES
# cefc35985646   cassandra:latest   "docker-entrypoint.s…"   About a minute ago   Up 14 seconds (health: starting)   7001/tcp, 9160/tcp, 0.0.0.0:7200->7000/tcp, [::]:7200->7000/tcp, 0.0.0.0:7299->7199/tcp, [::]:7299->7199/tcp, 0.0.0.0:9242->9042/tcp, [::]:9242->9042/tcp   cassandra02
# 1e6d94687116   cassandra:latest   "docker-entrypoint.s…"   About a minute ago   Up About a minute (healthy)        7001/tcp, 9160/tcp, 0.0.0.0:7199->7199/tcp, [::]:7199->7199/tcp, 0.0.0.0:7100->7000/tcp, [::]:7100->7000/tcp, 0.0.0.0:9142->9042/tcp, [::]:9142->9042/tcp   cassandra01
```

**Note** : Le démarrage complet peut prendre 5 minutes car les nœuds démarrent séquentiellement avec healthchecks. L'ordre de démarrage est :

1. cassandra01 (1er seed, peut démarrer en 1er)
2. cassandra02 (2ème seed, attend cassandra01 healthy)


#### Pour visualiser les logs de cassandra01 : 
```bash
docker logs cassandra01
```

#### 4°) Vérification du cluster (après 5-8 minutes)

#### Regarder les ports à l'écoute :
```bash
netstat -anl | grep 0:
```

#### Vérifier que les 2 conteneurs sont UP sinon attendre (non listé ou encore en train de joindre : 'UJ')
```bash
cd ~/cassandra-reaper
docker compose -f Cluster_2_noeuds_1_rack_1_DC_Prometheus_Grafana.yml ps
```

#### Vérifier le statut du cluster via nodetool
```bash
docker exec -it cassandra01 nodetool status
```
#### Vous devriez voir finalement les 2 nœuds cassandra avec le statut "UN" (Up Normal)
#### Le résultat devrait ressembler à :

```bash
Datacenter: ccu
===============
Status=Up/Down
|/ State=Normal/Leaving/Joining/Moving
--  Address     Load        Tokens  Owns (effective)  Host ID                               Rack
UN  10.17.64.6  70.2 KiB    16      100.0%            92543ec7-8948-429c-b750-af41c6a2542d  rack1
UN  10.17.64.5  104.34 KiB  16      100.0%            88d74876-8a3e-4bc6-8e09-6f4c0fccdd60  rack1

```


### 3.2 Vérifier l'accès JMX

Reaper se connecte aux nœuds via **JMX**. Les variables d'environnement suivantes
sont déjà positionnées dans le `docker-compose.yml` :

```yaml
- LOCAL_JMX=no
- JVM_EXTRA_OPTS=-Djava.rmi.server.hostname=<IP> -Dcom.sun.management.jmxremote.authenticate=false
```

Le port JMX **7199** est exposé sur chaque nœud (ex : `7199:7199` pour cassandra01).

> ⚠️ Dans cet environnement de formation, l'authentification JMX est désactivée.
> **Ne jamais faire cela en production.**

---

## 4. Intégration de Reaper dans docker-compose.yml

### 4.1 Ajouter le service `reaper`

Ajoutez le bloc suivant dans la section `services:` de votre `docker-compose.yml` 
**Cluster_2_noeuds_1_rack_1_DC_Prometheus_Grafana.yml**
**après** les blocs des exporters et **avant** Prometheus :



```yaml
# ─────────────────────────────────────────────────────────────
#  CASSANDRA REAPER
# ─────────────────────────────────────────────────────────────
  reaper:
    image: thelastpickle/cassandra-reaper:latest
    container_name: reaper
    restart: always
    depends_on:
      cassandra01:
        condition: service_healthy
      cassandra02:
        condition: service_healthy
    networks:
      cassandra_network:
        ipv4_address: 10.17.64.175
    volumes:
      - ${PWD}/monitoring/reaper/cassandra-reaper.yml:/etc/cassandra-reaper/cassandra-reaper.yml:ro
    command: ["cassandra-reaper"]          
    environment:
      - REAPER_AUTH_ENABLED=true
      - REAPER_AUTH_USER=admin
      - REAPER_AUTH_PASSWORD=admin
    ports:
      - "8080:8080"
      - "8090:8081"
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:8080/ping || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 10
      start_period: 60s
```

ce qui vous donnera ce fichier complet présent ici : 
**Cluster_2_noeuds_1_rack_1_DC_Prometheus_Grafana_Reaper.yml**

#### Affichage du fichier complet avec ajout service Reaper : 
```bash
cd ~/cassandra-reaper
cat Cluster_2_noeuds_1_rack_1_DC_Prometheus_Grafana_Reaper.yml
```


### 4.2 Explication des paramètres clés

| Paramètre | Valeur | Rôle |
|---|---|---|
| `REAPER_STORAGE_TYPE` | `cassandra` | Reaper stocke son état dans le cluster lui-même |
| `REAPER_CASS_LOCAL_DC` | `ccu` | DC préférentiel pour les lectures/écritures de Reaper |
| `REAPER_REPAIR_PARALLELISM` | `DATACENTER_AWARE` | Répare un DC à la fois, évite les tempêtes de lecture cross-DC |
| `REAPER_REPAIR_INTENSITY` | `0.5` | Utilise 50 % des ressources disponibles pendant la réparation |
| `REAPER_SEGMENT_COUNT_PER_NODE` | `16` | Découpe le token ring en 16 segments par nœud |

---

## 5. Création du keyspace de backend Reaper

Reaper a besoin d'un keyspace dédié **avant** son premier démarrage.

### 5.1 Se connecter à cqlsh

```bash
docker exec -it cassandra01 cqlsh
```

### 5.2 Créer le keyspace

```sql
CREATE KEYSPACE IF NOT EXISTS reaper_db
WITH replication = {
  'class': 'NetworkTopologyStrategy',
  'ccu': 1
}
AND durable_writes = true;
```

> **Remarque** : En production, utilisez un facteur de réplication de **3** par datacenter (1 DC = 3 noeuds minimum).
> Ici, 1 est suffisant pour le lab car nous n'avons que 2 nœuds par DC.

### 5.3 Vérifier le keyspace

```sql
DESCRIBE KEYSPACE reaper_db;
```
##### Affichage attendu :  
CREATE KEYSPACE reaper_db WITH replication = {'class': 'NetworkTopologyStrategy', 'ccu': '1'}  AND durable_writes = true;

##### On sort du cqlsh :  
```sql
EXIT;
```

---

## 6. Démarrage et vérification

### 6.1 Démarrer Reaper

```bash
docker compose -f Cluster_2_noeuds_1_rack_1_DC_Prometheus_Grafana_Reaper.yml up -d reaper
```

### 6.2 Suivre les logs

```bash
docker logs -f reaper
```

Attendez les messages indiquant que Reaper est connecté :

```
INFO  [...] Storage type used: cassandra
INFO  [...] Started @...ms
INFO  [...] Reaper is ready
```

> Le démarrage peut prendre **1 à 2 minutes** le temps que le schéma soit créé automatiquement
> dans le keyspace `reaper_db`.

### 6.3 Vérifier que les tables ont été créées

```bash
docker exec -it cassandra01 cqlsh -e "USE reaper_db; DESCRIBE TABLES;"
```

##### Affichage en retour :

```texte

Vous devriez voir des tables comme `cluster`, `repair_run`, `repair_schedule`, `repair_segment`, etc :

cluster                        repair_run_by_cluster_v2                 snapshot
diagnostic_event_subscription  repair_run_by_unit
leader                         repair_schedule_by_cluster_and_keyspace
node_metrics_v1                repair_schedule_v1
node_metrics_v3                repair_unit_v1
node_operations                running_reapers
percent_repaired_by_schedule   running_repairs
repair_run                     schema_migration
repair_run_by_cluster          schema_migration_leader

```

### 6.4 Test de connectivité

```bash
curl -si http://localhost:8080/cluster
```

Réponse attendue : 

```
HTTP/1.1 200 OK
Date: Sun, 22 Mar 2026 15:53:57 GMT
Content-Type: application/json
Vary: Accept-Encoding
Content-Length: 2
```

---

## 7. Prise en main de l'interface web

### 7.1 Accéder à l'interface

Ouvrez un navigateur et naviguez vers :

```
http://localhost:8080/webui/
```

Connectez-vous directement 
Si besoin (ça ne sera pas le cas normalement) :
- **Utilisateur** : `admin`
- **Mot de passe** : `admin`


### 7.2 Ajouter le cluster 'archivage-db'

1. Cliquez sur **"Add Cluster"**
2. Renseignez les champs :

| Champ | Valeur |
|---|---|
| **Seed node** | `10.17.64.5` |
| **JMX port** | `7199` |
| **JMX username** | *(laisser vide)* |
| **JMX password** | *(laisser vide)* |

3. Cliquez sur **"Add Cluster"**

Reaper découvre automatiquement les 2 nœuds via le gossip Cassandra.

### 7.3 Vérifier la topologie ainsi découverte

Dans le menu **Cluster**, en cliquant sur **archivage-db**, vous devriez voir :

```
archivage-db

Nodes: 2
Total load: 211.9 kB
Running repairs:

├── ccu  211.9 kB
 ├── rack1 : 211.9 kB
         1er noeud         2nd noeud          (sour forme de carrés verts)

     reaper_db

```

---

## 8. Lancer une réparation manuelle

### 8.1 Préparer un keyspace de test

Créez un keyspace et une table de test pour observer la réparation :

```bash
docker exec -it cassandra01 cqlsh
```

```sql
CREATE KEYSPACE IF NOT EXISTS test_repair WITH replication = {'class': 'NetworkTopologyStrategy', 'ccu': '1'}  AND durable_writes = true;
```

```sql
USE test_repair;
```

```sql
CREATE TABLE IF NOT EXISTS users (
  id UUID PRIMARY KEY,
  name TEXT,
  email TEXT,
  created_at TIMESTAMP
);
```

```sql
-- Insérer quelques données de test
INSERT INTO users (id, name, email, created_at)
VALUES (uuid(), 'Jon Snow', 'jon@winterfell.north', toTimestamp(now()));

INSERT INTO users (id, name, email, created_at)
VALUES (uuid(), 'Daenerys Targaryen', 'dany@dragonstone.sea', toTimestamp(now()));

INSERT INTO users (id, name, email, created_at)
VALUES (uuid(), 'Cersei Lannister', 'cersei@portreal.crown', toTimestamp(now()));

```

```sql

SELECT * FROM users LIMIT 10;

EXIT;
```

### 8.2 Déclencher une réparation via l'UI

1. Dans l'interface Reaper, cliquez sur **"Repair"** → **"Start a new repair"**
2. Renseignez :

| Champ | Valeur |
|---|---|
| **Cluster** | `archivage-db` |
| **Keyspace** | `test_repair` |
| **Owner** | `cassandra_test` |
| **Cause** |  *(laisser vide)* |
| **Tables** | *(laisser vide = toutes)* |
| **Blacklist** | *(laisser vide = aucune)* |
| **Nodes** | *(laisser vide = tous)* |
| **Datacenters** | `ccu` |
| **Segments per node** | `16` |
| **Parallelism** | `DC_Aware` |
| **Repair Intensity** | `0.5` |
| **Repair type** | `Full Subrange` |
| **Repair threads** | `2` |
| **Segment timeout** | `10` |

3. Cliquez sur **"Repair"**

### 8.3 Observer la progression

L'interface affiche :
- La **liste des segments** du token ring
- L'état de chaque segment : `NOT_STARTED` → `RUNNING` → `DONE`
- La **durée estimée** restante
- Les nœuds impliqués dans chaque segment

### 8.4 Déclencher via l'API REST (alternative)

Reaper expose une API REST complète :

```bash
# Authentification : récupérer un token JWT
TOKEN=$(curl -s -X POST http://localhost:8080/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"admin"}' | jq -r '.token')

# Lancer une réparation
curl -s -X POST "http://localhost:8080/repair_run" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "clusterName=formation&keyspace=test_repair&owner=formation_admin&intensity=0.5&repairParallelism=DATACENTER_AWARE"
```

---

## 9. Planifier des réparations automatiques

### 9.1 Créer un planning via l'UI

1. Cliquez sur **"Schedule"** → **"+ New Schedule"**
2. Configurez :

| Champ | Valeur |
|---|---|
| **Cluster** | `archivage-db` |
| **Keyspace** | `test_repair` |
| **Owner** | `ops_team` |
| **Start time** | *(heure de faible charge, ex : 02:00)* |
| **Interval in days** | `7` |
| **Percent unrepaired threshold** | `laisser vide` |
| **Adaptive** | `true` |

**Avanced settings** permet d'aller plus loin dans les options (intensité, parallèlisme, ...) 

3. Cliquez sur **"Add Schedule"**

### 9.2 Créer un planning via l'API

```bash
curl -s -X POST "http://localhost:8080/repair_schedule" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "clusterName=formation\
&keyspace=test_repair\
&owner=ops_team\
&scheduleDaysBetween=7\
&scheduleTriggerTime=$(date -u +%Y-%m-%dT02:00:00 -d 'tomorrow')\
&intensity=0.5\
&repairParallelism=DATACENTER_AWARE\
&incrementalRepair=false"
```

### 9.3 Bonnes pratiques de planification

```
┌────────────────────────────────────────────────────────────────────────┐
│                  Stratégie de réparation recommandée                   │
├─────────────────┬──────────────────────────────────────────────────────┤
│ gc_grace_seconds│ Valeur par défaut Cassandra : 864 000 s (10 jours)   │
│ Fréquence       │ Réparer TOUS les nœuds en < 10 jours                 │
│ Horaire         │ Nuit / week-end (faible charge)                      │
│ Intensité       │ 0.2-0.5 en production, 0.8 en lab                    │
│ Parallélisme    │ DATACENTER_AWARE (jamais PARALLEL en prod)           │
└─────────────────┴──────────────────────────────────────────────────────┘
```

> **Règle d'or** : La fréquence des réparations doit être **inférieure à `gc_grace_seconds`**.
> Si un nœud est absent plus de `gc_grace_seconds`, il faut le supprimer et le ré-ajouter.

---

## 10. Surveiller les réparations dans Grafana

### 10.1 Ajouter la cible Reaper dans Prometheus

Éditez le fichier `monitoring/prometheus/prometheus.yml` et ajoutez un job :

```yaml
scrape_configs:
  # ... jobs existants pour les exporters ...

  - job_name: 'cassandra-reaper'
    static_configs:
      - targets: ['10.17.64.175:8081']
    metrics_path: /prometheusMetrics
```

Rechargez la configuration Prometheus :

```bash
curl -X POST http://localhost:9090/-/reload
```

### 10.2 Vérifier les métriques dans Prometheus

Ouvrez `http://localhost:9090` et cherchez les métriques Reaper :

```promql
# Nombre total de segments réparés
reaper_segments_repaired_total

# Durée moyenne d'un segment de réparation
rate(reaper_repair_segment_duration_seconds_sum[5m])
/ rate(reaper_repair_segment_duration_seconds_count[5m])

# Réparations actives
reaper_active_repairs

# État des nœuds vu par Reaper
reaper_node_availability
```

### 10.3 Dashboard Grafana suggéré

Créez un fichier `monitoring/grafana/dashboards/reaper.json` avec les panneaux suivants :

| Panneau | Requête PromQL |
|---|---|
| Segments réparés / heure | `rate(reaper_segments_repaired_total[1h]) * 3600` |
| Durée médiane segment | `histogram_quantile(0.5, rate(reaper_repair_segment_duration_seconds_bucket[5m]))` |
| Réparations en cours | `reaper_active_repairs` |
| Santé des nœuds | `reaper_node_availability` |

> Vous pouvez importer le dashboard communautaire Grafana ID **10649** (Cassandra Reaper Overview).

---

## 11. Scénarios avancés

### 11.1 Simuler un nœud qui a manqué des données

**Objectif** : Comprendre pourquoi la réparation est nécessaire.

```bash
# 1. Arrêter cassandra03 temporairement
docker stop cassandra03
```
```bash
# 2. Insérer des données pendant son absence
docker exec -it cassandra01 cqlsh -e "
USE test_repair;
INSERT INTO users (id, name, email, created_at)
VALUES (uuid(), 'Arya Stark', 'arya@braavos.essos', toTimestamp(now()));
INSERT INTO users (id, name, email, created_at)
VALUES (uuid(), 'Sansa Stark', 'sansa@vale.moon', toTimestamp(now()));
"
```

```bash
# 3. Redémarrer cassandra03
docker start cassandra03
```

```bash
# 4. Vérifier le hint handoff (données manquées récupérées automatiquement si < 3h)
docker exec -it cassandra03 nodetool tpstats | grep -A3 "HintedHandoff"
```

```bash
# 5. Compter les données sur cassandra03 (peut différer de cassandra01)
docker exec -it cassandra03 nodetool tablestats test_repair.users | grep "Number of partitions"
```
```bash
docker exec -it cassandra01 nodetool tablestats test_repair.users | grep "Number of partitions"
```

```bash
# 6. Lancer une réparation depuis Reaper et observer la synchronisation
```

### 11.2 Réparation incrémentale vs complète

```bash
# Réparation complète (par défaut) : compare TOUTES les données
# → Coûteux mais garantit la cohérence totale
# → Utiliser périodiquement (hebdomadaire)

# Réparation incrémentale : ne compare que les SSTables non encore réparées
# → Plus rapide, moins d'I/O
# → Nécessite que les SSTables soient marquées "repaired"
# → Active via: REAPER_INCREMENTAL_REPAIR=true dans docker-compose
```

Dans l'UI Reaper, cochez **"Incremental repair"** lors de la création d'une réparation
pour tester ce mode.

### 11.3 Réparation d'un seul datacenter (supposons DC1 et DC2)

Pour réparer uniquement le DC `DC1` sans toucher au second DC `DC2` :

1. Dans **"New Repair"**, section **"Datacenters"**, sélectionnez uniquement le DC souhaité `DC1`
2. Ou via l'API :

```bash
curl -s -X POST "http://localhost:8080/repair_run" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "clusterName=formation&keyspace=test_repair&datacenters=DC1&owner=admin"
```

### 11.4 Interrompre et reprendre une réparation

```bash
# Lister les réparations en cours
curl -s "http://localhost:8080/repair_run?cluster=archivage-db&state=RUNNING" \
  -H "Authorization: Bearer $TOKEN" | jq '.[].id'
```

```bash
# Mettre en pause (remplacer <RUN_ID> par l'ID obtenu)
curl -s -X PUT "http://localhost:8080/repair_run/<RUN_ID>/state/PAUSED" \
  -H "Authorization: Bearer $TOKEN"
```

```bash
# Reprendre
curl -s -X PUT "http://localhost:8080/repair_run/<RUN_ID>/state/RUNNING" \
  -H "Authorization: Bearer $TOKEN"
```

---

## 12. Nettoyage

```bash
# Supprimer les réparations terminées de l'interface
# (via UI : onglet Repair → icône poubelle)

# Supprimer le service Reaper
docker compose stop reaper
docker compose rm -f reaper
```

```bash
# Supprimer le keyspace de backend (optionnel)
docker exec -it cassandra01 cqlsh -e "DROP KEYSPACE IF EXISTS reaper_db;"
```

```bash
# Supprimer le keyspace de test
docker exec -it cassandra01 cqlsh -e "DROP KEYSPACE IF EXISTS test_repair;"
```

---

## 13. Questions de validation

Répondez aux questions suivantes pour valider vos acquis :

1. **Qu'est-ce que `gc_grace_seconds` et pourquoi conditionne-t-il la fréquence des réparations ?**

2. **Quelle différence y a-t-il entre une réparation `SEQUENTIAL`, `PARALLEL` et `DATACENTER_AWARE` ?
   Laquelle est recommandée en production multi-DC et pourquoi ?**

3. **Pourquoi le keyspace `reaper_db` utilise-t-il `NetworkTopologyStrategy` avec un facteur
   de réplication par datacenter ?**

4. **Qu'est-ce qu'un segment de réparation ? Comment le paramètre `REAPER_SEGMENT_COUNT_PER_NODE`
   influence-t-il les performances et la granularité du suivi ?**

5. **Dans le scénario 11.1, que se passe-t-il si le nœud `cassandra03` reste arrêté plus de
   `max_hint_window_in_ms` (par défaut 3 heures) ? La réparation suffit-elle à récupérer
   les données ?**

6. **Quel est le rôle du paramètre `REAPER_REPAIR_INTENSITY` ? Quels sont les risques
   d'une intensité trop élevée en production ?**

---

## Annexe A — Variables d'environnement Reaper

| Variable | Description | Valeur lab |
|---|---|---|
| `REAPER_STORAGE_TYPE` | Backend de stockage (`memory`, `cassandra`, `postgres`) | `cassandra` |
| `REAPER_CASS_CONTACT_POINTS` | Nœuds de contact (JSON array) | `["10.17.64.151","10.17.64.152"]` |
| `REAPER_CASS_KEYSPACE` | Keyspace de stockage Reaper | `reaper_db` |
| `REAPER_CASS_LOCAL_DC` | DC local pour les requêtes Reaper | `ccu` |
| `REAPER_REPAIR_PARALLELISM` | Mode de parallélisme par défaut | `DATACENTER_AWARE` |
| `REAPER_REPAIR_INTENSITY` | Ratio de ressources utilisées (0.0–1.0) | `0.5` |
| `REAPER_SEGMENT_COUNT_PER_NODE` | Segments par nœud pour une réparation complète | `16` |
| `REAPER_SCHEDULE_DAYS_BETWEEN` | Intervalle par défaut entre planifications | `7` |
| `REAPER_AUTH_ENABLED` | Active l'authentification sur l'UI | `true` |
| `REAPER_JMX_AUTH` | Active l'auth JMX | `false` |
| `REAPER_METRICS_ENABLED` | Expose les métriques Prometheus | `true` |

## Annexe B — Ports exposés

| Service | Port hôte | Port conteneur | Usage |
|---|---|---|---|
| `reaper` | `8080` | `8080` | Interface web / API REST |
| `reaper` | `8090` | `8081` | Admin + métriques `/prometheusMetrics` |

## Annexe C — Commandes utiles

```bash
# État du service Reaper
docker inspect --format='{{.State.Health.Status}}' reaper

# Logs en temps réel
docker logs -f reaper 2>&1 | grep -E "(INFO|WARN|ERROR)"

# Test de l'API sans authentification
curl http://localhost:8080/webui

# Lister les clusters enregistrés
curl -u admin:admin http://localhost:8080/cluster

# Lister les réparations
curl -u admin:admin "http://localhost:8080/repair_run?cluster=formation"

# Lister les jobs de planifications de repair :
curl -u admin:admin "http://localhost:8080/repair_schedule?cluster=formation"
```
