-- Airflow metadata DB (read-only): every DAG's pause state, schedule and last 14 days of runs.
-- Names the V3 and V4 jobs that are actually running, not the ones a document says exist.
select d.dag_id, d.is_paused, d.is_active,
       left(coalesce(d.schedule_interval::text, d.timetable_description, ''), 28) schedule,
       d.next_dagrun::timestamp(0) next_run,
       r.runs_14d, r.ok_14d, r.failed_14d, r.running_now,
       r.last_start::timestamp(0) last_start, r.last_success::timestamp(0) last_success
from dag d
left join lateral (
  select count(*) filter (where start_date > now() - interval '14 days') runs_14d,
         count(*) filter (where start_date > now() - interval '14 days' and state='success') ok_14d,
         count(*) filter (where start_date > now() - interval '14 days' and state='failed') failed_14d,
         count(*) filter (where state='running') running_now,
         max(start_date) last_start,
         max(end_date) filter (where state='success') last_success
  from dag_run x where x.dag_id = d.dag_id) r on true
where d.is_active
order by d.is_paused, d.dag_id;
