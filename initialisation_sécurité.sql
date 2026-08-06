-- 1. Création du superuser et du rôle Reaper
CREATE ROLE IF NOT EXISTS superuser WITH PASSWORD = 'Mot_de_passe_superuser' AND SUPERUSER = true AND LOGIN = true;
CREATE ROLE IF NOT EXISTS reaper WITH PASSWORD = 'reaperdb' AND SUPERUSER = false AND LOGIN = true;

-- 2. Configuration de la réplication system_auth sur le DC 'dc1' avec RF=3
ALTER KEYSPACE "system_auth" 
WITH REPLICATION = {'class' : 'NetworkTopologyStrategy', 'dc1' : 3};

-- 3. Création du keyspace applicatif dc1
CREATE KEYSPACE IF NOT EXISTS keyspace_application
WITH REPLICATION = {'class': 'NetworkTopologyStrategy', 'dc1': 3}
AND DURABLE_WRITES = true;

-- 4. Création du keyspace de backend pour Reaper
CREATE KEYSPACE IF NOT EXISTS reaper_db
WITH REPLICATION = {'class': 'NetworkTopologyStrategy', 'dc1': 3}
AND DURABLE_WRITES = true;

-- 5. Attribution des privilèges pour Reaper
GRANT ALL PERMISSIONS ON KEYSPACE reaper_db TO reaper;
GRANT EXECUTE ON ALL FUNCTIONS IN KEYSPACE reaper_db TO reaper;