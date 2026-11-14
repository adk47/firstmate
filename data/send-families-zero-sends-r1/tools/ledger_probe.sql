-- Newest apply/judge decider row of each covered request. One probe of index decisions_req per id
-- (32,644 ids), never a scan. Run read-only:
--   sqlite3 -readonly /var/lib/hydra/credit-review/ledger.sqlite3 < ledger_probe.sql
-- with /tmp/sfz-covered.csv = "<request id>,<user id>" from covered_uvn.py.
CREATE TEMP TABLE c(rid TEXT PRIMARY KEY, uid INTEGER);
.mode csv
.import /tmp/sfz-covered.csv c
CREATE TEMP TABLE n AS
  SELECT c.rid, c.uid,
         (SELECT MAX(d.id) FROM decisions d WHERE d.request_id = c.rid AND d.mode IN ('apply', 'judge')) AS m
  FROM c;
CREATE TEMP TABLE k AS
  SELECT n.rid, n.uid,
         CASE WHEN n.m IS NULL THEN 'no apply/judge row'
              WHEN d.decision = 'hold' AND d.reason LIKE 'proof on file%' THEN 'hold: proof on file (stage 2 input)'
              WHEN d.decision = 'hold' THEN 'hold: other'
              ELSE d.decision END AS newest
  FROM n LEFT JOIN decisions d ON d.id = n.m;
.mode list
SELECT 'by newest row', newest, count(*) AS requests, count(DISTINCT uid) AS users FROM k GROUP BY 2 ORDER BY 3 DESC;
-- the selection (decide.UVN_TAKE_DECISIONS): no apply/judge row, or a newest row that is support or defer
SELECT 'selected', count(*) AS requests, count(DISTINCT uid) AS users FROM k
 WHERE newest IN ('no apply/judge row', 'support', 'defer');
-- users with NO proof-on-file hold on any covered request today: no verdict path at all
SELECT 'users with no stage-2 input today', count(*) FROM (
  SELECT uid FROM k GROUP BY uid HAVING sum(newest = 'hold: proof on file (stage 2 input)') = 0);
SELECT 'of them, selected', count(*) FROM (
  SELECT uid FROM k GROUP BY uid HAVING sum(newest = 'hold: proof on file (stage 2 input)') = 0
     AND sum(newest IN ('no apply/judge row', 'support', 'defer')) > 0);
SELECT 'hold: other, by reason', substr(d.reason, 1, 44), count(*), count(DISTINCT n.uid)
  FROM n JOIN decisions d ON d.id = n.m WHERE d.decision = 'hold' AND d.reason NOT LIKE 'proof on file%'
  GROUP BY 2 ORDER BY 3 DESC LIMIT 8;
EXPLAIN QUERY PLAN SELECT MAX(d.id) FROM decisions d WHERE d.request_id = 'x' AND d.mode IN ('apply', 'judge');
