-- Normaliza un DB creado por engram `dev` (pre-v3) antes del primer enroll en
-- Engram Cloud. Orden: abrir el DB una vez con la v3 (migra el esquema), aplicar
-- el legacy-map.<cliente>.sql si existe, y luego este archivo.
--
--   sqlite3 engram.db ".parameter set :home '/home/usuario'" ".read normalize-legacy.sql"
--
-- Por qué (gate del 2026-10-11): la build dev guardaba cada mem_save en una
-- única sesión `manual-save`, compartida por todos los proyectos. Al
-- sincronizar, esa sesión cambiaba de proyecto y arrastraba observaciones
-- ajenas al export de otro proyecto. Y una observación con content vacío
-- bloqueaba el push entero (`content is required for upsert`).
BEGIN;

-- 1. Basura: observaciones sin contenido. No aportan nada y el servidor las
--    rechaza.
DELETE FROM observations WHERE trim(ifnull(content, '')) = '';

-- 2. Partir `manual-save` en una sesión por proyecto, con la convención de v3.
INSERT OR IGNORE INTO sessions (id, project, directory, started_at, ended_at, summary)
SELECT DISTINCT 'manual-save-' || o.project, o.project, :home, s.started_at, s.ended_at, NULL
FROM observations o JOIN sessions s ON s.id = o.session_id
WHERE o.session_id = 'manual-save' AND ifnull(o.project, '') <> '';

UPDATE observations SET session_id = 'manual-save-' || project
WHERE session_id = 'manual-save' AND ifnull(project, '') <> '';

DELETE FROM sessions WHERE id = 'manual-save'
  AND NOT EXISTS (SELECT 1 FROM observations WHERE session_id = 'manual-save')
  AND NOT EXISTS (SELECT 1 FROM user_prompts WHERE session_id = 'manual-save');

-- 3. Sesiones sin directorio (lo mismo que haría el helper de upstream).
UPDATE sessions SET directory = :home WHERE ifnull(directory, '') = '';

COMMIT;

-- Verificación: no debe devolver filas. Si las hay, el instalador se detiene.
-- Las observaciones sin proyecto necesitan un legacy-map.<cliente>.sql.
SELECT 'obs sin proyecto', count(*) FROM observations
  WHERE ifnull(project, '') = '' HAVING count(*) > 0
UNION ALL
SELECT 'obs en manual-save', count(*) FROM observations
  WHERE session_id = 'manual-save' HAVING count(*) > 0
UNION ALL
SELECT 'obs con sesión de otro proyecto', count(*) FROM observations o
  JOIN sessions s ON s.id = o.session_id WHERE s.project <> o.project HAVING count(*) > 0;
