-- Mapeo de las observaciones sin proyecto del DB legacy de pc-ph (decidido el
-- 2026-10-11). Específico de ESTE cliente: en otra máquina los IDs son otras
-- observaciones. Por eso cada UPDATE exige ID y created_at a la vez; si no
-- casan las dos cosas, no toca nada y la verificación de normalize-legacy.sql
-- lo destapa.
BEGIN;

UPDATE observations SET project = 'floci'
WHERE ifnull(project, '') = '' AND (id, created_at) IN (
  VALUES (53, '2026-05-24 23:11:17'), (54, '2026-05-24 23:27:57'),
         (55, '2026-05-25 00:24:04'), (56, '2026-05-25 01:25:26'));

UPDATE observations SET project = 'personal'
WHERE ifnull(project, '') = '' AND (id, created_at) IN (
  VALUES (16, '2026-04-25 00:27:01'), (32, '2026-05-04 01:53:19'),
         (33, '2026-05-04 01:57:34'), (69, '2026-07-05 02:47:42'),
         (77, '2026-07-18 17:07:05'), (84, '2026-08-02 23:54:20'),
         (99, '2026-09-04 02:50:36'));

COMMIT;
