-- Every cube_analytics_* LEAF table in olap (partitions included: the cubes are partitioned by period, and a
-- partitioned parent reports 0 bytes), split into family + numeric generation and joined to cube_suffixes:
-- is this generation the served one (current_suffix), the staged one (staged_suffix), or neither?
with rel as (
  select c.relname, pg_total_relation_size(c.oid) bytes,
         regexp_match(c.relname, '^(cube_analytics_[a-z_]+?)_([0-9]+)(_[a-z0-9]+)?$') m
  from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public' and c.relkind = 'r' and c.relname like 'cube_analytics_%'
), j as (
  select r.relname, r.bytes, r.m[1] fam, r.m[2] gen,
         case when r.m is null then 'no-generation-suffix'
              when s.cube_name is null then 'family-not-in-cube_suffixes'
              when r.m[2] = s.current_suffix then 'served'
              when r.m[2] = s.staged_suffix then 'staged'
              else 'neither' end status
  from rel r left join cube_suffixes s on s.cube_name = r.m[1]
)
select coalesce(fam,'(unparsed)') family, status, count(*) leaf_rels, string_agg(distinct gen, ',' order by gen) gens,
       pg_size_pretty(sum(bytes)) size, sum(bytes) bytes
from j group by grouping sets ((1,2),(2)) order by 1 nulls last, 2;
select pg_size_pretty(sum(pg_total_relation_size(c.oid))) all_public_leaf_tables, count(*) n,
       pg_size_pretty(pg_database_size(current_database())) database_size
from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind='r';
select n.nspname, count(*) rels, pg_size_pretty(sum(pg_total_relation_size(c.oid))) size
from pg_class c join pg_namespace n on n.oid=c.relnamespace where c.relkind='r' and n.nspname not in ('pg_catalog','information_schema')
group by 1 order by sum(pg_total_relation_size(c.oid)) desc limit 8;
