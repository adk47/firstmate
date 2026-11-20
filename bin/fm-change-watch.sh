#!/usr/bin/env bash
# Post-merge change watch: watch a merged change BY EFFECT, not by content.
#
# A merge that touches a deployable service is normally verified at merge time
# by reading the new content on the live pods. That proves the change ARRIVED; it
# does not prove the service is healthy afterwards. This script registers one
# bounded watch per merged change, samples the affected Deployment's own signals
# against a pre-deploy baseline, and reports the FIRST regression as a wake and a
# steer so a bad change is caught minutes after the rollout, not hours later.
#
# Usage:
#   fm-change-watch.sh register <task-id> <pr-url>
#   fm-change-watch.sh due <watch-id>
#   fm-change-watch.sh drive <watch-id>
#   fm-change-watch.sh sample <watch-id> [<offset-seconds>]
#   fm-change-watch.sh verdict <watch-id>
#   fm-change-watch.sh gate <task-id> [--terminal-gap]
#   fm-change-watch.sh audit [<days>]
#   fm-change-watch.sh status [<watch-id>]
#   fm-change-watch.sh rederive [--apply] [<watch-id>...]
#   fm-change-watch.sh rescore [--apply] <watch-id>
#   fm-change-watch.sh doctor [<watch-id>]
#   fm-change-watch.sh claim <task-id> <probe-path> [<pr-url>]
#   fm-change-watch.sh acceptance <watch-id> <offset-seconds>
#   fm-change-watch.sh claims
#
# claim       Register a worker's done claim at claim time, before any PR may
#             exist: bind the task's acceptance probe by sha256 and write an
#             open claim row (watch id <task-id>-claim). Claiming again
#             replaces the claim. The "claim rows" section owns the contract.
# acceptance  Run the claim's bound acceptance probe at one of the claim offsets
#             (0 900 3600 21600) and rewrite the row: proven on the first exit 0,
#             absent when it still fails at the last offset, which also queues
#             one check wake. The probe is re-hashed against the claim's binding
#             and run from / under a clean environment with a bounded timeout; a
#             probe that changed records exit 125 without being run.
# claims      Print every open claim with its due offset and deadline, one
#             tab-separated line each, for the runner that takes the readings.
#
# register  Derive the affected Kubernetes Deployment(s) from the merged PR,
#           record the pre-deploy baseline, and arm one bounded schedule of
#           samples. For an H-DevOps pull request the targets are the
#           Deployment documents that the PR's diff hunks land in, across the
#           changed manifests under k8s/prod/, read at the PR's head commit so
#           the diff's line numbers apply; a target's namespace is the
#           document's own metadata.namespace, and a Deployment that declares
#           none is skipped with a stated reason, never guessed. When a hunk
#           cannot be placed in its manifest (no diff, or content that does not
#           match it) every Deployment in that manifest is watched and the
#           registration line says so. For an application repository the
#           targets are the Deployments that RUN this repository's image in a
#           production namespace, found by matching a container image's
#           repository name against the repository's own name and the aliases
#           in config/change-watch-repos (local, gitignored); a repository
#           whose Deployment names differ from its image name is mapped there,
#           and one that deploys to a host rather than the cluster is watched
#           through its own deploy workflow instead. A large family is capped
#           at MAX_TARGETS busiest Deployments and the registration line states
#           the cap. A repository whose map names more than one service is a
#           monorepo, so only the services the merged diff actually touches are
#           cluster targets: a path names a service by one of its segments, or
#           by the segment under the map's path: prefix, and a deployable path
#           no service owns is shared build input that keeps every Deployment in
#           scope. A diff whose every touched path is documentation, a test, a
#           monorepo's script, or non-deploy CI deploys nothing: the watch
#           completes clean, saying so when the kept targets hold no deploy
#           workflow run, because a run is still measured for that diff. A
#           repository that also has a Sentry project, and any workflow the map
#           names, become additional targets of their own whatever the diff
#           touches, since those reads never touch the cluster; a Sentry project
#           this home has no token for is not a target. A PR that touches no
#           deployable service registers nothing and says so, as does one that
#           only deletes a manifest, one whose only target could not be read,
#           one whose manifests could not be read, and one whose cluster image
#           inventory could not be read; each says which of those it was. Every
#           one of those still writes the merge's durable row, and one whose
#           surface could not be read records it as
#           unmeasurable-with-reason and queues the unmeasurable wake.
#           Every Kubernetes target records a rollout FINGERPRINT at
#           registration - its pod images plus its pods' pod-template-hash
#           labels - and the watch refuses to score it until that fingerprint
#           CHANGES, so a sample taken before the rollout lands measures the
#           release rather than the code it replaced. The template hash is why a
#           manifest change that rolls pods without touching an image (an env
#           value, a routing table) still opens the gate, and why a mutable tag or
#           a digest-pinned image still proves its own rollout. A target whose
#           fingerprint has not changed is recorded as awaiting the deploy, never
#           as health, unless its running image tag was already built from a
#           tree carrying the merge (the repository's build: spec): a watch
#           registered after its deploy is measured from registration, its
#           restarts and 5xx held to absolute bars because no pre-merge baseline
#           survives, and the registration, the verdict, and the row say so.
#           When the fingerprint cannot be read at registration the
#           target is still measured, and the clean completion, the unmeasurable
#           verdict, and the status line each say the rollout was never proven
#           for it.
#           Registering an existing watch whose drive stopped before the end of
#           its schedule, whose schedule ended unmeasurable, or whose row ended
#           absent re-arms it: a completed schedule, and any absent watch, is
#           reset and re-measured from that point, its samples, previous values
#           and read failures are cleared, its measurement epoch moves to the
#           re-registration, and its durable row goes back to open, so no
#           evidence from before the re-registration can score. The durable row
#           decides this as well as the verdict, so a deleted verdict cannot
#           hide a gap. A watch whose row ended `regressed` re-arms the same
#           way, keeping the verdict it replaced in
#           state/change-watch/<watch-id>/rearm-history and clearing any
#           recorded follow-up, because the regression was handed to follow-up
#           work and the shipped fix is what gets re-measured. A BETA regression
#           is not re-armed: it has no production targets to re-measure, so its
#           terminal row, beta reason and beta evidence stay in place and the
#           operator is told that re-measuring beta needs a new watch with its
#           own targets. Any other existing watch is left alone. Registration is read-only against the cluster; it
#           writes only under this home's state/ directory. Its forge reads
#           share one budget (default 60s) and its baseline capture the sample
#           budget below, so a merge or watcher cycle is never stalled by it.
# due       Condition hook for the armed watch: exit 0 when a scheduled sample
#           is due now, exit 1 otherwise. Pure and cheap; never runs a sample.
# drive     Action hook for the armed watch: take every remaining scheduled
#           sample in order, stopping at the first regression. This is the one
#           long-running child; it is armed through bin/fm-procevent-when.sh and
#           is never run in a conversational turn. A drive stopped before the
#           end of its schedule records "interrupted at +Nm" and is judged by
#           the readings it took: when those proved the change, the change is
#           proven and the reason says the schedule stopped early; otherwise
#           the row is unmeasurable-with-reason and one check wake is queued.
# sample    Read every metric for every target, compare each to its baseline
#           with a stated bar, and append one sample record. Degrades to
#           "unmeasured" per metric rather than failing the whole watch.
# verdict   Print "change-watch clean", "change-watch unmeasurable-with-reason:
#           <reason>", "change-watch interrupted at +Nm",
#           "change-watch absent at +Nm: <reason>", or
#           "change-watch regressed at +Nm on <metric> (<value> vs baseline <value>)".
#           Clean means every Deployment target had at least one scored reading
#           across the schedule AND the +6h reading scored something AND at least
#           one target recorded at registration, because the Deployment bar
#           holds vacuously for a
#           watch that recorded no target to apply it to. A reading that measured nothing
#           earlier in the schedule is disclosed in the reason and superseded by
#           the later evidence, because an early read can fail for a reason the
#           later ones do not share. A reading made entirely of samples still
#           awaiting their rollout read nothing, so it is not a measurement and a
#           watch whose +6h reading is one of those ends unmeasurable naming that
#           case. A Deployment target that never scored is a
#           read that failed and makes the row unmeasurable-with-reason; a
#           metric key or a sentry/ and run/ target that never scored is a
#           coverage gap, named in the reason and in the row's
#           unmeasured_metrics, never a verdict on its own. A missing +6h reading
#           is never a pass. A regression any sample recorded is the verdict and
#           outranks every later reading, including a later one that scored
#           clean, because a bad deploy stays bad until it is reverted. A beta
#           regression exits 1 as well,
#           so a beta failure is never read as a pass. The exit status is the
#           done-claim block: 0 for clean or a recorded regression, 1 for
#           unmeasurable-with-reason, absent, interrupted, or a beta regression.
# gate      The done-claim gate for one task: exit 0 only when every watch that
#           task registered has reached a terminal state that is not a
#           measurement gap. A watch still running is not a pass, and an
#           unmeasurable or absent watch is a failure, so a task cannot claim done
#           while its merge has no evidence. bin/fm-teardown.sh calls it with
#           --terminal-gap, which fails for a terminal measurement gap and for a
#           regression whose follow-up work item is not yet recorded: a running
#           watch never blocks teardown, because state/change-watch/ is not a task
#           record and keeps sampling after the task is gone. Both
#           modes decide from the watch's durable row, so deleting the verdict
#           file never turns a failing row into a pass, and a row whose merge
#           never created a watch directory is still seen. A recorded
#           regression fails the done-claim gate, and --terminal-gap passes it
#           only after the follow-up work item is recorded with
#           followup <watch-id> <work-item>.
#           A pass requires having read the named task's OWN evidence: a state
#           root that does not exist fails, naming the resolved path, and so
#           does a root that holds no watch row and no <task>.meta record of
#           the task - even one that holds other watches, which are not this
#           task's evidence (a lane worktree's own state/, which git never
#           carries). Only that record makes a watch-less task a pass.
# followup  Record the follow-up work item a regressed watch's regression was
#           handed to. Writes work_item, recorded_epoch and the reason to
#           <watch dir>/followup; refuses a watch with no recorded regression
#           and a malformed work-item reference. gate <task-id> --terminal-gap
#           passes a recorded regression once this file exists.
# audit     The 7-day acceptance, measured. It fails (exit 1) when any status log
#           under state/ carries the literal "change-watch completed unmeasured"
#           line, or when any durable row completed inside the window ended
#           unmeasurable-with-reason or absent. Default window 7 days.
# status    Print one line per registered watch (all of them, or one).
# rederive  Re-derive the terminal state of durable rows already on disk from the
#           readings those rows and their watch directories still hold, under
#           the same rule verdict applies. It is the repair for rows written by
#           an earlier, stricter derivation: hand-editing a row would be writing
#           a verdict nobody measured. Only a row the old rule called
#           unmeasurable-with-reason, or one it called proven from an
#           all-awaiting +6h reading, is re-derived: an open row belongs to a
#           drive that has not finished, and a regressed or not-applicable row
#           is already a verdict. A re-derivation also rewrites the verdict file
#           to the state it derived. A watch registered before
#           rows existed has no row to rewrite, so the readings it still holds
#           get one written and completed at its last sample. Every row it writes
#           or rewrites carries derived_epoch, so a reconstructed row is never
#           mistaken for one a live drive wrote; a live row that appeared while
#           the sweep ran wins, and a directory whose drive has not finished is
#           left alone. Dry run unless --apply: it prints the rule, a census of
#           the no-row watches, how many rows would change, and the first ten of
#           them, and rewrites nothing. A row rescore rewrote is left alone,
#           because its verdict rests on a reading newer than the samples.
# rescore   Re-derive one regressed or absent row's terminal verdict from the
#           readings it recorded plus the deciding metric read again now with
#           the current reader, and store that deciding reading in the row's
#           "rescore" field. It is the repair for a verdict an earlier scoring
#           rule reached from one reading. The comparison against the recorded
#           baseline is: an unmeasured baseline is "unmeasured" (never 0 and
#           never a regression) for every metric whose bar is relative to it or
#           is deploy_run; a reading equal to its baseline is "unchanged"
#           for a metric whose bar reads that baseline (and for deploy_run), so
#           0 against 0 is never a regression; otherwise the metric's own bar
#           decides "regressed" or "within-bar", including an absolute metric
#           re-read equal to its baseline. A deploy_run re-read below 1 is
#           absent; a watch whose only metric is the deciding one is proven by a
#           re-read taken after +6h, which for deploy_run is the run carrying
#           the merge succeeding (its bar never reads the baseline) and for any
#           other metric must not be unmeasured; anything else falls back to the
#           readings-only rule rederive applies, ignoring the stale regression
#           flags. It refuses (exit 1, row untouched) an open row, a row whose
#           state rests on no single reading, a row with no watch directory,
#           and a metric the current reader cannot read now: no reading is no
#           verdict. Dry run unless --apply.
# doctor    Live self-test of the read path. It prints the kubeconfig in use,
#           proves the cluster answers, and with a watch id reads every target
#           live: a Deployment target must return its pods and its pod images, a
#           pool-backed target its own resolved pool, a Sentry target its
#           project, and a workflow target its run list. It also replays the
#           reasons the last sample recorded for each unmeasured metric, so the
#           question "why was nothing measured" is answered with evidence
#           instead of silence. A read that fails, times out, or returns no data
#           is a stated "doctor: FAIL" line and a non-zero exit.
#
# Kubeconfig: the cluster is read with the first of FM_CW_KUBECONFIG, the path
# on the first non-comment line of config/change-watch-kubeconfig (local,
# gitignored), an operator's own KUBECONFIG, and ~/.kube/mcp-viewer.kubeconfig
# (the read-only production reader this home uses) that is set and readable.
# The ambient ~/.kube/config default is used only when none of those exist,
# because that default can point at a cluster this home cannot reach - which is
# exactly how every watch once completed unmeasured while looking healthy. A
# sample proves the cluster answers once before reading any metric and records
# the reason for every metric it could not read.
#
# Beta stage: a merged change is read against the pre-production copy of the
# service that serves it BEFORE any production target is read, so a change that
# breaks something is caught while it is still only in beta rather than after it
# is live. The beta map is the built-in entry plus the home's own
# config/change-watch-beta (local, gitignored): one "<key> <namespace>/<deployment>"
# per line, where <key> is a repository name or a changed-path prefix, and a home
# line replaces the built-in line for that key. Built in:
#   web-credits-next -> muso-dev/credits-gate
#
# Registration runs seconds after the merge, so the beta target is still running
# the pre-change code. The stage therefore records the target's pre-merge pod
# fingerprint, captures its baseline from that pre-change state, waits for the
# merged sha to reach the target, and only then reads. The wait is bounded by
# FM_CW_BETA_WAIT_ATTEMPTS x FM_CW_BETA_POLL_SECONDS, at most 60 seconds because
# registration runs both on the merge path and synchronously inside the watcher's
# merged-poll landing path after that cycle's beat: a longer wait would leave the
# watcher beacon stale past the guard grace and print a false WATCHER DOWN. A
# rollout that has not landed inside that bound is stated as unmeasured rather
# than read as a pass, and so is a target whose pre-merge pod fingerprint could
# not be read at registration, because an unproven landing is never treated as
# landed.
#
# The readings go through the same metric reader a sample uses, scored against
# that beta baseline rather than an absolute bar, because an absolute bar on a dev
# environment is not evidence about the change. The beta bars are relative to the
# beta baseline: oomkilled regressed when value > baseline, rss_ratio when
# value > baseline + 0.05, and every other beta metric by its production bar,
# which is already relative to the baseline it is given. A metric whose baseline
# could not be read is left unscored and named in the verdict, never scored
# absolutely.
#
# Five verdicts, recorded in the watch's beta record:
#   beta clean: <n> metric(s) read on <target>, none crossed its bar
#   beta clean: <n> of <total> metric(s) read on <target>, none crossed its bar;
#               unmeasured: <metrics>
#   beta clean: nothing to measure: no changed path is served by a beta target (<map>)
#   beta unmeasured: <reason> (targets: <target>)
#   beta regressed on <metric> (<value> vs baseline <baseline>) at <target>
#
# A beta failure is a beta failure: it is recorded as that verdict, reported on
# its own wake and its own steer, and the production watch is never armed for it,
# so it can be neither read as a production regression nor upgraded to a
# production pass. A change touching no beta-served path completes the stage
# clean with the reason stated and the production watch arms as before.
#
# The stage runs before the production baseline is captured, and that ordering is
# the contract rather than an accident of layout: FM_CW_TRACE records every
# metric read with its stage, and a test asserts the order from that record.
#
# Metrics, bars, and windows:
#   http_5xx_per_min     5xx responses per minute from the pods' own access
#                        logs. When the per-container line cap is hit the rate
#                        is taken over the span the read lines actually cover,
#                        so a busy service is never divided by a window it did
#                        not fill. Regressed when value > 3x baseline AND
#                        value > 1/min.
#   restarts             total container restartCount across the Deployment's
#                        pods; regressed when value > baseline + 1.
#   oomkilled            OOMKilled container terminations at or after the
#                        baseline epoch; regressed when value > 0.
#   p95_ms               request p95 latency where the service exposes it;
#                        regressed when value > 3x baseline AND > baseline+100ms.
#   pgbouncer_cl_waiting clients waiting on the Deployment's own pgbouncer pool:
#                        the pod spec's DB_HOST/DB_PORT/DB_NAME (secret refs
#                        resolved), the pooler endpoint behind that Service, then
#                        SHOW POOLS filtered to that database. The console is
#                        read on the pooler host as `ssh -n ubuntu@<host>`
#                        running `sudo -u postgres psql -h /var/run/postgresql
#                        -p <port> -U pgbouncer pgbouncer -Ac 'SHOW POOLS'`, the
#                        admin unix socket the house wiki records as the form
#                        that answers without a password; the read is bounded
#                        by the remaining sample budget. A pool that cannot be
#                        resolved at registration is unmeasured for the whole
#                        watch. Regressed when value > 0 on two consecutive
#                        samples.
#   rss_ratio            highest container working set as a fraction of its
#                        memory limit; regressed when value > 0.85.
#   sentry_new_issues    issues first seen at or after the baseline epoch at
#                        level error or fatal; regressed when value > baseline
#                        AND value >= 3. Its target is sentry/<project>. It is
#                        not read until the watch's own landing is proven: the
#                        watched Deployments' rollout when the watch has any,
#                        otherwise its deploy workflow's run for this merge.
#                        Without a Sentry token or a mapped project it is
#                        unmeasured for the whole watch, with the reason
#                        recorded.
#   deploy_run           the repository's own deploy workflow as 1 when the
#                        latest scheduled or dispatched run whose tree carries
#                        the merged commit completed successfully, and 0 when
#                        that run failed, was cancelled, or timed out; regressed
#                        when value is 0, because a failed deploy is definite
#                        whether or not any run existed at registration (so its
#                        baseline reads "unmeasured"). Its target is
#                        run/<owner>/<repo>#<workflow-path>. The latest carrier
#                        decides rather than the first: a deploy that failed and
#                        was retried successfully has landed, while one that
#                        succeeded and was then retried into a failure has not.
#                        No run yet, one still in flight, or a containment read
#                        that failed or was cut is awaiting the deploy and
#                        unmeasured, as is a merge sha the forge cannot name: a
#                        run that does not carry the merge is never scored as
#                        this release's success or regression, and neither is an
#                        unreadable answer treated as one that does not carry it.
# The baseline window is the 60 minutes before the change's rollout start, read
# as a level for counters (restarts, oomkilled, rss_ratio) and as a rate for the
# others. An unmeasured metric is skipped, never scored as a pass, and a metric
# with a relative bar (http_5xx_per_min, restarts, p95_ms, sentry_new_issues)
# whose baseline could not be read is recorded but never scored. Every metric a
# sample could not read leaves its reason in the watch's read-failures record,
# and both status and doctor replay them.
#
# An absent metric is never implied to be healthy: a clean verdict counts only
# the metrics that were actually read, and the completion note and status line
# name every metric key no sample ever scored, target included, so a release
# watched only for restarts and memory says exactly that and a target whose own
# pool or pods were never read is named as the gap it is.
#
# Schedule: +5m, +15m, +30m, then hourly to +12h. Samples stop at the first
# regression. On a clean +12h the watch appends one note to the task's status
# log and, when that note has no gap to report, records one wiki observation; a
# clean ending that did leave a metric unmeasured or a rollout unproven says so
# in the note instead. A +12h that cannot be proven writes NO status note at
# all: it is a failure, so it queues a check wake and records the row.
#
# Awaiting the deploy is not a measurement gap. A sample taken before the
# watched rollout landed has nothing to read yet, so it is recorded as awaiting
# rather than as a failed read, and it never counts against a proven verdict.
# A watch whose rollout never landed at all still ends unmeasurable, because its
# Deployments never scored and the verdict names them.
#
# Durable row: every merge writes exactly one row at
# state/change-watch/rows/<watch-id>.json, holding a reading for every
# scheduled offset, the real-user check, and a terminal state of proven /
# regressed / absent / unmeasurable-with-reason (plus open while the watch runs,
# and not-applicable for a merge that touched no deployable surface at all, where
# a read that failed instead records unmeasurable-with-reason). Absent means the
# deploy run carrying the merge failed, so the change never reached production;
# it is a failure, never a regression of the running service. A merge whose diff
# touches nothing deployable records deploy_expected=no, keeps no deploy
# workflow target, and records "deploy": "not-applicable" in its row, so a
# failed deploy run is not-applicable to it.
# state/change-watch/ is
# not a task record, so bin/fm-teardown.sh never removes it and the row outlives
# the task. The schema is owned by the "durable row" section below.
#
# Reporting: the first regression appends one
#   check: change-watch <task-id> <pr-url> <metric> regressed
# wake to the durable wake queue and steers the owning task through
# bin/fm-send.sh with the numbers; an interrupted drive whose readings did not
# prove the change appends one
#   check: change-watch <task-id> <pr-url> interrupted at +Nm
# wake; and a schedule that ends unmeasurable appends one
#   check: change-watch <task-id> <pr-url> unmeasurable (<reason>)
# wake, because an unmeasurable watch is a failure and not a quiet completion.
# All are best-effort and never fail a merge.
#
# Read-only against the cluster. No model calls. No new fleet workers: the
# watcher's existing process-event runner drives the registered watch. One
# sample, and the baseline capture at registration, are each bounded by a hard
# budget (default 25s). That budget bounds the cluster reads only: every metric
# they cannot reach inside it is recorded unmeasured, while the Sentry and
# deploy-workflow reads go over the network under their own bounds and are never
# costed against a budget the pod reads spent.
#
# Test seams (all optional, all inert in production):
#   FM_CW_NOW              fixed current epoch (integer) instead of `date +%s`
#   FM_CW_FORGE_DIR        directory replacing every forge read (files.txt,
#                          merge-epoch, head-ref, merge-sha, diff.txt,
#                          content/<path>)
#   FM_CW_HDEVOPS_K8S_DIR  k8s/prod tree of an H-DevOps checkout, the last-resort
#                          way to resolve an application repository to a Deployment
#   FM_CW_KUBECONFIG       kubeconfig file used for every cluster read
#   FM_CW_CONFIG_DIR       directory replacing the home's config/ directory,
#                          where change-watch-kubeconfig, change-watch-repos and
#                          change-watch-beta live
#   FM_CW_MAX_TARGETS      cap on Deployments watched for one repository (default 8)
#   FM_CW_WORKLOADS_DIR    directory replacing the live image inventory: a file
#                          workloads holds "ns<TAB>name<TAB>replicas<TAB>images",
#                          images comma- or space-separated
#   FM_CW_SENTRY_VAULT     Sentry credential file (default ~/.config/muso/sentry-vault.json)
#   FM_CW_SENTRY_DIR       directory of stubbed Sentry responses: issues-<project>.json
#   FM_STATE_OVERRIDE      state root to read and write (default $FM_HOME/state).
#                          It is used only when it names an existing directory,
#                          and every subcommand that reads a watch, row, or claim
#                          refuses a state root that is not there instead of
#                          reporting nothing, naming the path: a state root that
#                          does not exist is a wrong home, not a home with no
#                          watches, and a lane worktree's own state/ is exactly
#                          that case, since git never carries it.
#   FM_CW_GH               gh command used for the deploy-run target (default gh)
#   FM_CW_GH_DIR           directory of stubbed gh responses:
#                          runs-<owner>-<repo>-<workflow-path with / and space as _>.json,
#                          contains-<head-sha> listing the shas that run's
#                          tree carries, one per line, and
#                          build-<owner>-<repo>-<workflow-path as above>-<run-number>
#                          holding the build log line naming the commit that
#                          run built
#   FM_CW_FORGE_TIMEOUT    per-call bound on a forge read (default 12s)
#   FM_CW_FORGE_BUDGET     total bound on forge reads in one register (default 60s)
#   FM_CW_SAMPLE_DEADLINE  hard budget for one sample or baseline capture (default 25)
#   FM_CW_CLUSTER_DIR      directory of metric series replacing cluster reads:
#                          <metric>.<target>.<window>, one value per line, empty
#                          line = unmeasured; the target is ns/deploy with "/"
#                          replaced by "_". pool.<target> holds one line
#                          "ip<TAB>port<TAB>database" replacing the pool
#                          resolution (absent = unresolvable).
#   FM_CW_ARM_CMD          command replacing bin/fm-procevent-when.sh for arming
#   FM_CW_SEND_CMD         command replacing bin/fm-send.sh for the lane steer
#   FM_CW_SLEEP_CMD        command replacing `sleep` for the drive loop
#   FM_CW_TRACE            file every metric read appends
#                          "<stage><TAB><metric><TAB><target>" to, where stage
#                          is beta or prod: the read order is asserted from it
#   FM_CW_BETA_WAIT_ATTEMPTS  fingerprint reads to wait for the beta rollout
#                          to land before reading beta (default 4)
#   FM_CW_BETA_POLL_SECONDS   pause between those reads (default 15); either
#                          value that is not a numeral falls back to its own
#                          default, and the product is clamped to 60 seconds
#   FM_CW_NO_WIKI          set to 1 to skip the wiki note with a printed notice
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# An override that names no directory is a caller pointing at a home that does
# not exist. Reading there finds no watch, and "no watch" must never be how a
# missing home reports itself, so every subcommand refuses it up front.
if [ -n "${FM_STATE_OVERRIDE:-}" ] && [ ! -d "$FM_STATE_OVERRIDE" ]; then
  case "${1:-}" in
    ''|-h|--help|help) ;;
    *)
      printf 'error: FM_STATE_OVERRIDE names %s, which is not an existing directory, so no change watch can be read or written there\n' \
        "$FM_STATE_OVERRIDE" >&2
      exit 1
      ;;
  esac
fi
# Whether the state root existed before anything ran: sourcing fm-wake-lib.sh
# creates it, so a later -d test cannot tell a real home from a lane worktree
# whose state/ was just made empty.
CW_STATE_FOUND=0
[ ! -d "$STATE" ] || CW_STATE_FOUND=1

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

WATCH_ROOT="$STATE/change-watch"
SCHEDULE_OFFSETS="300 900 1800 3600 7200 10800 14400 18000 21600 25200 28800 32400 36000 39600 43200"
K8S_METRICS="restarts oomkilled rss_ratio http_5xx_per_min p95_ms pgbouncer_cl_waiting"
SENTRY_METRICS="sentry_new_issues"
RUN_METRICS="deploy_run"
# The beta stage reads the metrics a dev target can actually answer. The pool
# metric stays with the production watch, which resolves a pool per production
# target.
BETA_METRICS="restarts oomkilled rss_ratio http_5xx_per_min p95_ms"
# The rollout wait is bounded because registration runs on the merge path and,
# when the watcher's merged-poll landing path registers in process, after that
# cycle's beat: a wait longer than the guard grace would leave the watcher beacon
# stale and print a false WATCHER DOWN. So the whole wait stays inside a minute
# and a configured product above that is clamped rather than trusted.
BETA_WAIT_ATTEMPTS=${FM_CW_BETA_WAIT_ATTEMPTS:-4}
BETA_POLL_SECONDS=${FM_CW_BETA_POLL_SECONDS:-15}
BETA_WAIT_CEILING_SECONDS=60
# Normalize a configured count: anything but decimal digits is not a count, a
# value wider than the ceiling is above every usable bound, and leading zeros are
# stripped so no arithmetic below reads one as an octal literal.
cw_beta_bound() {  # <value> <default> <ceiling>
  local v=$1 zeros
  case "$v" in ''|*[!0-9]*) printf '%s\n' "$2"; return 0 ;; esac
  zeros=${v%%[!0]*}
  v=${v#"$zeros"}
  [ -n "$v" ] || v=0
  [ "${#v}" -le "${#3}" ] || v=$3
  printf '%s\n' "$v"
}
BETA_WAIT_ATTEMPTS=$(cw_beta_bound "$BETA_WAIT_ATTEMPTS" 4 "$BETA_WAIT_CEILING_SECONDS")
BETA_POLL_SECONDS=$(cw_beta_bound "$BETA_POLL_SECONDS" 15 "$BETA_WAIT_CEILING_SECONDS")
[ "$BETA_POLL_SECONDS" -ge 1 ] || BETA_POLL_SECONDS=1
[ "$BETA_POLL_SECONDS" -le "$BETA_WAIT_CEILING_SECONDS" ] \
  || BETA_POLL_SECONDS=$BETA_WAIT_CEILING_SECONDS
BETA_WAIT_MAX=$((BETA_WAIT_CEILING_SECONDS / BETA_POLL_SECONDS))
[ "$BETA_WAIT_MAX" -ge 1 ] || BETA_WAIT_MAX=1
[ "$BETA_WAIT_ATTEMPTS" -ge 1 ] || BETA_WAIT_ATTEMPTS=1
[ "$BETA_WAIT_ATTEMPTS" -le "$BETA_WAIT_MAX" ] || BETA_WAIT_ATTEMPTS=$BETA_WAIT_MAX
# The built-in beta map: the pre-production copy of each service that has one.
CW_BETA_BUILTIN='web-credits-next muso-dev/credits-gate'
BASELINE_WINDOW_SECONDS=3600
SAMPLE_WINDOW_SECONDS=300
LOG_TAIL_LINES=2000
KUBECTL_TIMEOUT=4s
FORGE_TIMEOUT=${FM_CW_FORGE_TIMEOUT:-12}
FORGE_BUDGET_SECONDS=${FM_CW_FORGE_BUDGET:-60}
# Hard budget for one sample or one baseline capture: once it elapses, every
# remaining metric is recorded unmeasured so a slow or unreachable read can
# never run a sample, a merge, or a watcher cycle past its bound.
SAMPLE_DEADLINE_SECONDS=${FM_CW_SAMPLE_DEADLINE:-25}
MAX_MANIFEST_READS=20
# Cap on Deployments watched for one repository: a large image family (the
# industry-data-processing family alone is 21 Deployments in production) cannot
# be sampled inside one sample budget, so the busiest MAX_TARGETS are watched and
# the registration line states the cap instead of silently dropping the rest.
MAX_TARGETS=${FM_CW_MAX_TARGETS:-8}
# A Deployment is a watch target only when it runs in a production namespace:
# a dev, test, drill, or staging copy is not the release.
PROD_NAMESPACE_EXCLUDE='-dev|-test|-tests|-staging|-stage|-drill|-pr-'
TARGET_NAME_EXCLUDE='-test$'
SENTRY_VAULT=${FM_CW_SENTRY_VAULT:-$HOME/.config/muso/sentry-vault.json}
SENTRY_MIN_NEW=3
SENTRY_HTTP_TIMEOUT=6
POOLER_SSH_USER=ubuntu
POOLER_SOCKET_DIR=/var/run/postgresql
POOLER_DEFAULT_HOST=10.0.0.17
POOLER_DEFAULT_PORT=6432

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
notice() { printf 'notice: %s\n' "$1" >&2; }
usage() {
  awk 'NR == 1 { next } /^set -u$/ { exit } { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
  exit 2
}

cw_now() {
  if [ -n "${FM_CW_NOW:-}" ]; then
    printf '%s\n' "$FM_CW_NOW"
  else
    date +%s
  fi
}

CW_FORGE_START=$(cw_now)
CW_BUDGET_START=''
CW_CONFIG_DIR=${FM_CW_CONFIG_DIR:-$FM_HOME/config}
CW_KUBECONFIG=''
CW_KUBECONFIG_SOURCE=''

cw_kubectl() { kubectl --request-timeout="$KUBECTL_TIMEOUT" "$@"; }

# Resolve the kubeconfig every cluster read uses, and export it once so a
# subshell, a background reader, and a by-hand reproduction all see the same
# file. Precedence: an explicit FM_CW_KUBECONFIG, the home's own
# config/change-watch-kubeconfig, an operator's KUBECONFIG, then the read-only
# production reader this house ships. The ambient default is last on purpose:
# when it points at a cluster this home cannot reach, every watch completed
# unmeasured while its record still read as a normal watch.
cw_kubeconfig_init() {
  local source configured candidate
  configured=''
  if [ -f "$CW_CONFIG_DIR/change-watch-kubeconfig" ]; then
    configured=$(sed -n 's/^[[:space:]]*#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d; p; q' \
      "$CW_CONFIG_DIR/change-watch-kubeconfig" 2>/dev/null || true)
  fi
  # Candidates are walked in precedence order and each one is tested for
  # readability as it is offered: an unreadable file is stated and skipped so the
  # next candidate still gets its turn. Ending the walk at the first unreadable
  # file is what silently moved reads onto the ambient default.
  for source in FM_CW_KUBECONFIG config/change-watch-kubeconfig KUBECONFIG mcp-viewer; do
    case "$source" in
      FM_CW_KUBECONFIG) candidate=${FM_CW_KUBECONFIG:-} ;;
      config/change-watch-kubeconfig) candidate=$configured ;;
      KUBECONFIG) candidate=${KUBECONFIG:-}; candidate=${candidate%%:*} ;;
      mcp-viewer) candidate=$HOME/.kube/mcp-viewer.kubeconfig ;;
    esac
    [ -n "$candidate" ] || continue
    if [ ! -r "$candidate" ]; then
      printf 'notice: change-watch: kubeconfig %s (%s) is unreadable; trying the next one\n' \
        "$candidate" "$source" >&2
      continue
    fi
    CW_KUBECONFIG=$candidate
    CW_KUBECONFIG_SOURCE=$source
    export KUBECONFIG="$candidate"
    return 0
  done
  CW_KUBECONFIG=''
  CW_KUBECONFIG_SOURCE='ambient default'
  return 0
}

# One cheap proof that the cluster answers, run before a sample spends its
# budget on metric reads that would each fail the same way.
cw_cluster_probe() {
  local out
  # A stubbed series directory stands in for every cluster read, so the probe
  # has nothing to prove.
  [ -z "${FM_CW_CLUSTER_DIR:-}" ] || return 0
  command -v kubectl >/dev/null 2>&1 || { printf 'kubectl not installed\n'; return 1; }
  if out=$(cw_kubectl get --raw=/version 2>&1 >/dev/null); then
    return 0
  fi
  printf '%s\n' "${out:-unreadable}" | grep -v '^$' | tail -1 | cut -c1-200
  return 1
}

# Bound one forge read per call and all forge reads of this process together, so
# a hung CLI or a wide PR can never stall the merge or watcher path. A caller
# that has to leave the rest of a sample's budget for other metrics passes the
# epoch it must be done by, and no single call runs past it.
cw_forge_run_until() {  # <deadline-epoch|''> <command...>
  local deadline=$1 left
  shift
  left=$(( FORGE_BUDGET_SECONDS - ($(cw_now) - CW_FORGE_START) ))
  if [ -n "$deadline" ]; then
    deadline=$(( deadline - $(cw_now) ))
    [ "$deadline" -gt 0 ] || return 124
    [ "$deadline" -ge "$left" ] || left=$deadline
  fi
  [ "$left" -gt 0 ] || return 124
  [ "$left" -lt "$FORGE_TIMEOUT" ] || left=$FORGE_TIMEOUT
  fm_run_timed "$left" "$@" 2>/dev/null
}

cw_forge_run() {
  cw_forge_run_until '' "$@"
}

# Every read-scoped cache and budget starts with the sample, because the armed
# drive is one long-lived process that takes every sample in-process: a budget
# or a memo spent at +5m must not decide the read at +6h.
cw_budget_start() {
  CW_BUDGET_START=$(cw_now)
  CW_FORGE_START=$(cw_now)
  CW_POD_FACTS_CACHE=''
  CW_WORKLOADS_CACHE=''
  CW_SELECTOR_CACHE=''
  CW_MERGE_SHA_CACHE=''
  CW_TARGET_CARRIED_CACHE=''
  CW_TARGET_CARRIED_EVIDENCE=''
  CW_TARGET_CARRIED_REASON=''
  [ -z "$CW_POOL_BAD_HOSTS_FILE" ] || : > "$CW_POOL_BAD_HOSTS_FILE" 2>/dev/null || true
}
cw_within_budget() { [ $(( $(cw_now) - CW_BUDGET_START )) -lt "$SAMPLE_DEADLINE_SECONDS" ]; }
cw_budget_left() {
  local used=0 left
  [ -z "$CW_BUDGET_START" ] || used=$(( $(cw_now) - CW_BUDGET_START ))
  left=$(( SAMPLE_DEADLINE_SECONDS - used ))
  [ "$left" -gt 0 ] || return 1
  printf '%s\n' "$left"
}

# Stable content hash of a string (shasum or sha256sum; empty when neither is
# available, in which case the watch name falls back to a path-safe prefix).
cw_hash() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum 2>/dev/null | awk '{print $1}'
  else
    printf '%s' "$1" | tr -c 'A-Za-z0-9-' '-'
  fi
}

# Which stage is reading. The beta stage sets this for the duration of its reads
# so the read trace records who read what, and every other reader stays prod.
CW_STAGE=prod

# Record one metric read in the trace when a trace file is configured. Inert
# otherwise, so a production home pays nothing for it.
cw_trace() {  # <metric> <target>
  [ -z "${FM_CW_TRACE:-}" ] || printf '%s\t%s\t%s\n' "$CW_STAGE" "$1" "$2" >> "$FM_CW_TRACE"
}

# --- watch records ------------------------------------------------------------

cw_watch_id() { printf '%s-%s\n' "$1" "$2"; }
cw_watch_dir() { printf '%s/%s\n' "$WATCH_ROOT" "$1"; }
cw_meta_path() { printf '%s/watch.meta\n' "$(cw_watch_dir "$1")"; }
cw_targets_path() { printf '%s/targets\n' "$(cw_watch_dir "$1")"; }
cw_pools_path() { printf '%s/pools\n' "$(cw_watch_dir "$1")"; }
# Extra target kinds: a Sentry project and a deploy workflow are watched
# alongside the Deployments, and each is its own line in its own record so a
# watch with no cluster targets still has targets.
cw_sentry_path() { printf '%s/sentry\n' "$(cw_watch_dir "$1")"; }
cw_runs_path() { printf '%s/runs\n' "$(cw_watch_dir "$1")"; }
# The pod images and rollout fingerprint a Kubernetes target had at registration,
# the evidence the
# rollout must replace before the target is scored.
cw_landed_path() { printf '%s/images-at-register\n' "$(cw_watch_dir "$1")"; }
cw_landed_at_path() { printf '%s/landed-at\n' "$(cw_watch_dir "$1")"; }
# Why each metric of the last sample could not be read.
cw_reasons_path() { printf '%s/read-failures\n' "$(cw_watch_dir "$1")"; }
cw_reasons_begin() {
  : > "$(cw_reasons_path "$1")" 2>/dev/null || true
}
cw_record_reason() {  # <watch-id> <key> <reason>
  local id=$1 key=$2 reason=$3
  [ -n "$key" ] || return 0
  { printf '%s\t%s\n' "$key" "$(printf '%s' "${reason:-unmeasured}" | tr '\t\n' '  ' | cut -c1-200)"; } \
    >> "$(cw_reasons_path "$id")" 2>/dev/null || true
}
cw_baseline_path() { printf '%s/baseline\n' "$(cw_watch_dir "$1")"; }
cw_schedule_path() { printf '%s/schedule\n' "$(cw_watch_dir "$1")"; }
cw_samples_path() { printf '%s/samples.log\n' "$(cw_watch_dir "$1")"; }
cw_verdict_path() { printf '%s/verdict\n' "$(cw_watch_dir "$1")"; }
cw_followup_path() { printf '%s/followup\n' "$(cw_watch_dir "$1")"; }
cw_rearm_history_path() { printf '%s/rearm-history\n' "$(cw_watch_dir "$1")"; }
cw_sampled_path() { printf '%s/sampled\n' "$(cw_watch_dir "$1")"; }
cw_drive_pid_path() { printf '%s/drive.pid\n' "$(cw_watch_dir "$1")"; }
cw_drive_alive_path() { printf '%s/drive.alive\n' "$(cw_watch_dir "$1")"; }
cw_drive_identity_path() { printf '%s/drive.identity\n' "$(cw_watch_dir "$1")"; }
cw_last_path() { printf '%s/last.%s\n' "$(cw_watch_dir "$1")" "$2"; }

cw_meta_get() {  # <watch-id> <key>
  local file
  file=$(cw_meta_path "$1")
  [ -f "$file" ] || return 1
  grep "^$2=" "$file" | tail -1 | cut -d= -f2- || true
}

cw_meta_set() {  # <watch-id> <key> <value>
  local file tmp
  file=$(cw_meta_path "$1")
  [ -f "$file" ] || return 1
  tmp=$(umask 077; mktemp "$(dirname "$file")/.cw.XXXXXX") || return 1
  awk -v key="$2" -v value="$3" '
    BEGIN { done = 0 }
    index($0, key "=") == 1 { if (!done) { print key "=" value; done = 1 }; next }
    { print }
    END { if (!done) print key "=" value }
  ' "$file" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" && mv -f -- "$tmp" "$file"
}

cw_watch_exists() {
  local dir
  dir=$(cw_watch_dir "$1")
  [ -d "$dir" ] && [ ! -L "$dir" ] && [ -f "$dir/watch.meta" ]
}

# Whether the resolved state root holds <task>'s own record. A lane worktree's
# state/ holds none, so finding no watch there is not a finding.
cw_task_record_exists() {  # <task-id>
  [ -f "$STATE/$1.meta" ]
}

# A named watch that is not there, stated with the root it was looked for in so
# a missing home is never mistaken for a missing watch.
cw_die_unknown_watch() {  # <watch-id>
  if [ "$CW_STATE_FOUND" -eq 0 ]; then
    die "unknown watch: $1 (the state root could not be found at $STATE)"
  fi
  die "unknown watch: $1 (no watch directory under $WATCH_ROOT)"
}

# Whether a durable row carries a rescore's deciding reading.
cw_row_rescored() {  # <watch-id>
  grep -q '"rescore": {' "$(cw_row_path "$1")" 2>/dev/null
}

# atomic private write from stdin
cw_write() {  # <path>
  local path=$1 tmp
  tmp=$(umask 077; mktemp "$(dirname "$path")/.cw.XXXXXX") || return 1
  cat > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$path"
}

# --- forge seam ---------------------------------------------------------------

# LIVE QUERY (forge) - changed paths of the merged PR, one per line. GitHub is
# read through gh; anything else degrades to no file list, so register reports
# that it cannot derive a target rather than guessing one.
cw_forge_files() {  # <url> <provider> <owner> <repo> <number>
  if [ -n "${FM_CW_FORGE_DIR:-}" ]; then
    [ -f "$FM_CW_FORGE_DIR/files.txt" ] || return 1
    cat "$FM_CW_FORGE_DIR/files.txt"
    return 0
  fi
  case "$2" in
    github)
      command -v gh >/dev/null 2>&1 || return 1
      cw_forge_run gh pr view "$1" --json files -q '.files[].path' || return 1
      ;;
    *) return 1 ;;
  esac
}

# LIVE QUERY (forge) - the merged PR's unified diff.
cw_forge_diff() {  # <url> <provider>
  if [ -n "${FM_CW_FORGE_DIR:-}" ]; then
    [ -f "$FM_CW_FORGE_DIR/diff.txt" ] || return 1
    cat "$FM_CW_FORGE_DIR/diff.txt"
    return 0
  fi
  case "$2" in
    github)
      command -v gh >/dev/null 2>&1 || return 1
      cw_forge_run gh pr diff "$1" || return 1
      ;;
    *) return 1 ;;
  esac
}

# LIVE QUERY (forge) - merge/rollout epoch of the merged change.
cw_forge_merge_epoch() {  # <url> <provider>
  if [ -n "${FM_CW_FORGE_DIR:-}" ]; then
    [ -f "$FM_CW_FORGE_DIR/merge-epoch" ] || return 1
    cat "$FM_CW_FORGE_DIR/merge-epoch"
    return 0
  fi
  local iso
  case "$2" in
    github)
      command -v gh >/dev/null 2>&1 || return 1
      iso=$(cw_forge_run gh pr view "$1" --json mergedAt -q .mergedAt) || return 1
      ;;
    *) return 1 ;;
  esac
  cw_iso_to_epoch "$iso"
}

cw_iso_to_epoch() {  # <iso8601>
  local iso=$1 out
  [ -n "$iso" ] || return 1
  if out=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null); then
    printf '%s\n' "$out"; return 0
  fi
  if out=$(date -u -d "$iso" +%s 2>/dev/null); then
    printf '%s\n' "$out"; return 0
  fi
  return 1
}

# LIVE QUERY (forge) - one file's content at the merged commit.
cw_forge_content() {  # <owner> <repo> <path> <ref>
  if [ -n "${FM_CW_FORGE_DIR:-}" ]; then
    [ -f "$FM_CW_FORGE_DIR/content/$3" ] || return 1
    cat "$FM_CW_FORGE_DIR/content/$3"
    return 0
  fi
  command -v gh >/dev/null 2>&1 || return 1
  cw_forge_run gh api "repos/$1/$2/contents/$3?ref=$4" --jq .content \
    | base64 -d 2>/dev/null || return 1
}

# LIVE QUERY (forge) - head commit sha of the merged pull request, the commit
# the PR diff's new-file line numbers refer to.
cw_forge_head_ref() {  # <url>
  if [ -n "${FM_CW_FORGE_DIR:-}" ]; then
    [ -f "$FM_CW_FORGE_DIR/head-ref" ] || return 1
    cat "$FM_CW_FORGE_DIR/head-ref"
    return 0
  fi
  command -v gh >/dev/null 2>&1 || return 1
  cw_forge_run gh pr view "$1" --json headRefOid -q .headRefOid || return 1
}

# LIVE QUERY (forge) - the commit the merged change landed as, the sha a deploy
# run has to carry before it says anything about this release.
cw_forge_merge_sha() {  # <url>
  if [ -n "${FM_CW_FORGE_DIR:-}" ]; then
    [ -f "$FM_CW_FORGE_DIR/merge-sha" ] || return 1
    cat "$FM_CW_FORGE_DIR/merge-sha"
    return 0
  fi
  local sha
  # A stubbed run list means a stubbed forge: never reach the live gh from a test.
  [ -z "${FM_CW_GH_DIR:-}" ] || return 1
  command -v gh >/dev/null 2>&1 || return 1
  sha=$(cw_forge_run gh pr view "$1" --json mergeCommit -q '.mergeCommit.oid // empty') || return 1
  [ -n "$sha" ] || return 1
  printf '%s\n' "$sha"
}

# LIVE QUERY (forge) - success when <head-sha>'s history contains <base-sha>: the
# run built a tree that carries the merged change. A run of an older branch tip
# carries it too, and a run of a tag or a side branch does not. A read that failed
# or was cut returns 3, so a caller never mistakes it for a tree that lacks the
# merge.
cw_forge_run_carries() {  # <owner/repo> <base-sha> <head-sha> [<deadline-epoch>]
  local repo=$1 base=$2 head=$3 deadline=${4:-} state
  [ -n "$base" ] && [ -n "$head" ] || return 3
  if [ -n "${FM_CW_GH_DIR:-}" ]; then
    # A stubbed forge lists the shas each run's tree carries, one per line.
    [ -f "$FM_CW_GH_DIR/contains-$head" ] || return 3
    grep -qxF -- "$base" "$FM_CW_GH_DIR/contains-$head"
    return $?
  fi
  state=$(cw_forge_carries_state "$repo" "$base" "$head" "$deadline")
  case "$state" in
    carried) return 0 ;;
    not) return 1 ;;
  esac
  return 3
}

# LIVE QUERY (forge) - the same containment question answered as carried, not,
# or unreadable, so a tree proven to lack the merge can be remembered while a read
# that failed is asked again on the next sample.
cw_forge_carries_state() {  # <owner/repo> <base-sha> <head-sha> [<deadline-epoch>]
  local repo=$1 base=$2 head=$3 deadline=${4:-} gh_cmd=${FM_CW_GH:-gh} status
  if [ -z "$base" ] || [ -z "$head" ]; then
    printf 'unreadable\n'
    return 0
  fi
  if [ "$base" = "$head" ]; then
    printf 'carried\n'
    return 0
  fi
  if [ -n "${FM_CW_GH_DIR:-}" ]; then
    if [ ! -f "$FM_CW_GH_DIR/contains-$head" ]; then
      printf 'unreadable\n'
    elif grep -qxF -- "$base" "$FM_CW_GH_DIR/contains-$head"; then
      printf 'carried\n'
    else
      printf 'not\n'
    fi
    return 0
  fi
  command -v "$gh_cmd" >/dev/null 2>&1 || { printf 'unreadable\n'; return 0; }
  status=$(cw_forge_run_until "$deadline" "$gh_cmd" api "repos/$repo/compare/$base...$head" --jq .status) || status=''
  case "$status" in
    ahead|identical) printf 'carried\n' ;;
    behind|diverged) printf 'not\n' ;;
    *) printf 'unreadable\n' ;;
  esac
}

# LIVE QUERY (forge) - the commit an image tag was built from, for a repository
# whose deploy workflow tags its images <prefix>-<run-number> (the H-DevOps
# deploy workflows tag YYYYMMDD-<run-number>). The run with that number states
# the commit it resolved and built in one log line,
#   Resolved <repository> <branch> -> <40-hex sha>   (the arrow is U+2192),
# so the job that resolves it (determine-env, else the run's first jobs) is read
# for that line. Prints the full sha, or fails when the run or the line cannot be
# read. The run list is the workflow's newest 100 runs, so an image older than
# that is unreadable rather than guessed.
cw_image_build_sha() {  # <owner/repo> <workflow-path> <run-number> <project-repo-name> [<deadline-epoch>]
  local repo=$1 workflow=$2 number=$3 name=$4 deadline=${5:-} gh_cmd=${FM_CW_GH:-gh}
  local arrow=$'\xe2\x86\x92' run_id jobs job_id log sha='' tried=0
  if [ -n "${FM_CW_GH_DIR:-}" ]; then
    local safe=${workflow//[\/ ]/_}
    local file="$FM_CW_GH_DIR/build-${repo//\//-}-$safe-$number"
    [ -f "$file" ] || return 1
    sha=$(grep -oE '[0-9a-f]{40}' "$file" | head -1)
    [ -n "$sha" ] || return 1
    printf '%s\n' "$sha"
    return 0
  fi
  # A stubbed forge without stubbed runs is a test: never reach the live gh.
  [ -z "${FM_CW_FORGE_DIR:-}" ] || return 1
  command -v "$gh_cmd" >/dev/null 2>&1 || return 1
  run_id=$(cw_forge_run_until "$deadline" "$gh_cmd" api "repos/$repo/actions/workflows/${workflow##*/}/runs?per_page=100" \
    --jq ".workflow_runs[] | select(.run_number == $number) | .id" | head -1) || return 1
  case "$run_id" in ''|*[!0-9]*) return 1 ;; esac
  jobs=$(cw_forge_run_until "$deadline" "$gh_cmd" api "repos/$repo/actions/runs/$run_id/jobs?per_page=100" \
    --jq '.jobs[] | "\(.id)\t\(.name)"') || return 1
  # The resolving job first, then at most two more, so a run that never logs the
  # line costs three log reads, not one per job.
  jobs=$(printf '%s\n' "$jobs" | awk -F'\t' '$2 == "determine-env" { print $1 }'
    printf '%s\n' "$jobs" | awk -F'\t' '$2 != "determine-env" && $1 != "" { print $1 }')
  while IFS= read -r job_id; do
    case "$job_id" in ''|*[!0-9]*) continue ;; esac
    [ "$tried" -lt 3 ] || break
    tried=$((tried + 1))
    log=$(cw_forge_run_until "$deadline" "$gh_cmd" api "repos/$repo/actions/jobs/$job_id/logs") || continue
    sha=$(printf '%s\n' "$log" \
      | LC_ALL=C grep -oE "Resolved [^ ]*$name [^ ]+ $arrow [0-9a-f]{40}" \
      | head -1 | LC_ALL=C grep -oE '[0-9a-f]{40}$' || true)
    [ -z "$sha" ] || break
  done <<JOBS
$jobs
JOBS
  [ -n "$sha" ] || return 1
  printf '%s\n' "$sha"
}

# The commit a watched merge landed as, or nothing when the forge cannot name it.
# Memoized for the sample: a watch reads it once and every deploy-workflow read
# that sample reuses it, so the sha never costs more than one forge call.
CW_MERGE_SHA_CACHE=''
cw_merge_sha() {  # <watch-id>
  local id=$1 url sha key
  [ -n "$id" ] || return 0
  key="w${id#w}"
  while IFS=$'\t' read -r k v; do
    [ "$k" = "$key" ] || continue
    printf '%s\n' "$v"
    return 0
  done <<CACHE
$CW_MERGE_SHA_CACHE
CACHE
  url=$(cw_meta_get "$id" pr_url 2>/dev/null || true)
  sha=''
  if [ -n "$url" ]; then
    sha=$(cw_forge_merge_sha "$url" 2>/dev/null || true)
  fi
  CW_MERGE_SHA_CACHE="$CW_MERGE_SHA_CACHE$key	$sha
"
  [ -n "$sha" ] || return 0
  printf '%s\n' "$sha"
}

# The build-carries-merge answer for the sample, keyed by target: the gate is
# asked once per metric, so one target must not spend the sample budget on the
# same build read six times. An unreadable answer is remembered here too, for
# this sample only, and asked again at the next one.
CW_TARGET_CARRIED_CACHE=''
CW_TARGET_CARRIED_EVIDENCE=''
CW_TARGET_CARRIED_REASON=''

# --- deployment derivation ----------------------------------------------------

# Documents of a Kubernetes manifest stream (stdin), one per line as
# "start<TAB>end<TAB>kind<TAB>namespace<TAB>name" with 1-based inclusive line
# ranges. The name and namespace are the top-level metadata's own keys.
cw_manifest_docs() {
  awk '
    function flush(end) {
      if (kind != "" && end >= start) printf "%d\t%d\t%s\t%s\t%s\n", start, end, kind, ns, name
      start = NR + 1; kind = ""; ns = ""; name = ""; meta = 0; cind = 0
    }
    BEGIN { start = 1 }
    /^---[[:space:]]*$/ { flush(NR - 1); next }
    /^kind:[[:space:]]*/ { kind = $2; gsub(/["\047]/, "", kind); next }
    /^[^[:space:]#]/ { meta = ($0 ~ /^metadata:/); cind = 0; next }
    meta && /^[[:space:]]+[^[:space:]]/ {
      match($0, /^[[:space:]]+/)
      if (cind == 0) cind = RLENGTH
      if (RLENGTH != cind) next
      if ($1 == "name:" && name == "") { name = $2; gsub(/["\047]/, "", name) }
      else if ($1 == "namespace:" && ns == "") { ns = $2; gsub(/["\047]/, "", ns) }
    }
    END { flush(NR) }
  '
}

# Deployments declared in a manifest stream (stdin): "namespace<TAB>name", with
# an empty namespace when the document declares none.
cw_manifest_deployments() {
  cw_manifest_docs | awk -F'\t' '$3 == "Deployment" && $5 != "" { print $4 "\t" $5 }'
}

# Changed lines of a unified diff (stdin) as "path<TAB>new-file-line", one per
# added line and one per removed line at the position it was removed from; a
# file the diff deletes is one "path<TAB>removed" line instead.
cw_diff_changed_lines() {
  awk '
    /^diff --git / { path = ""; old = ""; inhunk = 0; next }
    /^--- / && !inhunk { old = $2; sub(/^a\//, "", old); next }
    /^\+\+\+ / {
      path = $2; sub(/^b\//, "", path); inhunk = 0
      if (path == "/dev/null") { path = ""; if (old != "" && old != "/dev/null") print old "\tremoved" }
      next
    }
    /^@@ / {
      match($0, /\+[0-9]+/)
      cur = substr($0, RSTART + 1, RLENGTH - 1) + 0
      if (cur < 1) cur = 1
      inhunk = 1
      next
    }
    !inhunk || path == "" { next }
    /^\\/ { next }
    /^\+/ { print path "\t" cur; cur++; next }
    /^-/ { print path "\t" cur; next }
    { cur++ }
  ' | sort -u
}

# LIVE QUERY (cluster) - every Deployment's namespace, name, replicas, and
# container images, one "ns<TAB>name<TAB>replicas<TAB>images" line each. A
# Deployment with more than one container renders its images space-separated, so
# a reader splits the field on commas and whitespace alike. One call answers the
# whole inventory, which keeps registering an application release cheap enough
# to run inside a merge hook. An unreadable cluster prints nothing and its caller
# records the reason.
cw_live_workloads() {
  if [ -n "${CW_WORKLOADS_CACHE:-}" ]; then
    printf '%s' "$CW_WORKLOADS_CACHE"
    return 0
  fi
  local out
  if [ -n "${FM_CW_WORKLOADS_DIR:-}" ]; then
    [ -f "$FM_CW_WORKLOADS_DIR/workloads" ] || return 1
    out=$(cat "$FM_CW_WORKLOADS_DIR/workloads")
  else
    command -v kubectl >/dev/null 2>&1 || return 1
    out=$(cw_kubectl get deploy -A \
      -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.status.replicas}{"\t"}{.spec.template.spec.containers[*].image}{"\n"}{end}' \
      2>/dev/null) || return 1
  fi
  [ -n "$out" ] || return 1
  CW_WORKLOADS_CACHE=$out
  printf '%s' "$out"
}

# The built-in repository map: the aliases an image name does not carry itself,
# the Sentry project a repository reports into, and the deploy workflow of a
# repository that reaches a host rather than the cluster. A home extends or
# overrides it in config/change-watch-repos (never sourced), whose lines are
# "<repo> <spec>..." with each spec one of
#   <namespace>/<deployment>   an explicit Deployment target
#   <deployment>               a Deployment in muso-prod
#   image:<name>               match Deployments running an image named <name>
#   sentry:<project-slug>      the repository's Sentry project
#   run:<owner>/<repo>#<workflow-path>   the repository's deploy workflow
#                                  (a path such as .github/workflows/deploy.yml,
#                                  so the spec stays one whitespace-free token)
#   path:<prefix>              where a monorepo keeps its service directories,
#                                  such as services or apps; a deployable path
#                                  under it that names no service is shared build
#                                  input every service of that repository consumes
#   build:<owner>/<repo>#<workflow-path>   the workflow that builds the
#                                  repository's images, tagging each
#                                  <prefix>-<run-number> and logging the commit
#                                  it built as "Resolved <repo> <branch> -> <sha>";
#                                  it maps a running image to its commit, so a
#                                  merge already running at registration is
#                                  measured instead of awaited (cw_target_landed)

# The home's repository map with comments removed. A `#` starts a comment only at
# the start of a line or after whitespace, because a `run:` spec carries one
# inside `<owner>/<repo>#<workflow-path>`.
cw_repo_map_clean() {
  sed -e 's/^#.*$//' -e 's/[[:space:]]#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    "$CW_CONFIG_DIR/change-watch-repos" 2>/dev/null | grep -v '^$' || true
}

cw_repo_map_lines() {
  cat <<'BUILTIN'
core-backend image:core-backend sentry:core-backend build:Muso-AI/H-DevOps#.github/workflows/deploy-core-backend.yaml
industry-data-processing image:industry-data-processing build:Muso-AI/H-DevOps#.github/workflows/deploy-idp.yaml
web-credits-next image:web-credits-next sentry:credits-web-next
muso-messaging messaging/notify-gateway messaging/send-gateway messaging/preferences
hydra run:Muso-AI/hydra#.github/workflows/deploy.yml
BUILTIN
  if [ -f "$CW_CONFIG_DIR/change-watch-repos" ]; then
    cw_repo_map_clean
  fi
}

# Specs mapped to one repository, in order: the home's own line when it names
# the repository (so a local map replaces the built-in one), else the built-in
# line.
cw_repo_specs() {  # <repo>
  local repo=$1 line specs=''
  if [ -f "$CW_CONFIG_DIR/change-watch-repos" ]; then
    specs=$(cw_repo_map_clean \
      | awk -v r="$repo" '$1 == r { $1 = ""; sub(/^ /, ""); print }' | paste -sd ' ' -)
  fi
  [ -z "$specs" ] || { printf '%s\n' "$specs"; return 0; }
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "$(printf '%s' "$line" | awk '{print $1}')" = "$repo" ] || continue
    specs="$specs $(printf '%s' "$line" | cut -d' ' -f2-)"
  done <<MAP
$(cw_repo_map_lines)
MAP
  printf '%s\n' "$(printf '%s' "$specs" | sed -e 's/^ *//' -e 's/ *$//')"
}

# The image build mapping a repository declares, as
# "<owner/repo><TAB><workflow-path><TAB><image-name>", where the image name is the
# repository's first image: spec, else the repository name. Fails when it declares
# no build: spec.
cw_repo_build_spec() {  # <repo>
  local spec image='' build=''
  for spec in $(cw_repo_specs "$1"); do
    case "$spec" in
      build:*) build=${spec#build:} ;;
      image:*) [ -n "$image" ] || image=${spec#image:} ;;
    esac
  done
  case "$build" in *?'#'?*) ;; *) return 1 ;; esac
  printf '%s\t%s\t%s\n' "${build%%#*}" "${build#*#}" "${image:-$1}"
}

# Production-only filter for a Deployment: a dev, test, drill, or staging copy is
# not the release, and a test copy of a production Deployment is not a target.
cw_target_eligible() {  # <ns> <name>
  local ns=$1 name=$2
  case "$ns" in '') return 1 ;; esac
  if printf '%s' "$ns" | grep -Eq "($PROD_NAMESPACE_EXCLUDE)"; then return 1; fi
  if printf '%s' "$name" | grep -Eq "($TARGET_NAME_EXCLUDE)"; then return 1; fi
  return 0
}

# Resolve one spec to "target<TAB>ns<TAB>name" or "sentry<TAB>slug" or
# "run<TAB>owner/repo<TAB>workflow" lines, ranked by replica count and capped at
# MAX_TARGETS so a large image family is watched by its busiest members.
cw_spec_targets() {  # <spec>
  local spec=$1 arg='' ns name matched='' total inventory
  case "$spec" in
    sentry:*) printf 'sentry\t%s\n' "${spec#sentry:}"; return 0 ;;
    run:*)
      arg=${spec#run:}
      printf 'run\t%s\t%s\n' "${arg%%#*}" "${arg#*#}"
      return 0
      ;;
    image:*) arg=${spec#image:} ;;
    path:*|build:*|'') return 0 ;;
    */*) ns=${spec%%/*}; name=${spec#*/}
      cw_target_eligible "$ns" "$name" || return 0
      printf 'target\t%s\t%s\n' "$ns" "$name"
      return 0
      ;;
    *) ns=muso-prod; name=$spec
      cw_target_eligible "$ns" "$name" || return 0
      printf 'target\t%s\t%s\n' "$ns" "$name"
      return 0
      ;;
  esac
  [ -n "$arg" ] || return 0
  # Match every production Deployment running an image whose repository name is
  # <arg>, then keep the busiest MAX_TARGETS. An inventory that cannot be read is
  # stated, so it is distinguishable from a repository that deploys nothing.
  if ! inventory=$(cw_live_workloads 2>/dev/null); then
    printf 'note\timage inventory unread: no Deployment of image:%s could be resolved\t\n' "$arg"
    return 0
  fi
  matched=$(printf '%s\n' "$inventory" | awk -F'\t' -v want="$arg" '
    {
      ns = $1; name = $2; replicas = $3 + 0; images = $4
      n = split(images, list, /[,[:space:]]+/)
      for (i = 1; i <= n; i++) {
        repo = list[i]
        sub(/^.*\//, "", repo)
        sub(/@.*$/, "", repo)
        sub(/:.*$/, "", repo)
        if (repo == want) { printf "%s\t%s\t%d\n", ns, name, replicas; break }
      }
    }' | while IFS=$'\t' read -r ns name replicas; do
      cw_target_eligible "$ns" "$name" || continue
      printf '%s\t%s\t%s\n' "$replicas" "$ns" "$name"
    done | sort -t$'\t' -k1,1nr -k2,2 -k3,3)
  [ -n "$matched" ] || return 0
  total=$(printf '%s\n' "$matched" | grep -c '' || true)
  if [ "$total" -gt "$MAX_TARGETS" ]; then
    printf 'note\tcapped: watching the %s busiest of %s image:%s Deployments\t\n' \
      "$MAX_TARGETS" "$total" "$arg"
  fi
  printf '%s\n' "$matched" | head -n "$MAX_TARGETS" \
    | while IFS=$'\t' read -r replicas ns name; do
        [ -n "$ns" ] || continue
        printf 'target\t%s\t%s\n' "$ns" "$name"
      done
}

# Resolve an application repository's name to "target<TAB>namespace<TAB>name"
# from a local H-DevOps checkout's k8s/prod tree. Read-only; prints nothing when
# unresolved or when the Deployment declares no namespace. Used only when the
# image inventory resolves nothing for the repository. LIVE QUERY (checkout).
cw_service_targets() {  # <service>
  local root=${FM_CW_HDEVOPS_K8S_DIR:-$FM_HOME/projects/H-DevOps/k8s/prod}
  local service=$1 dir manifest ns name
  [ -d "$root" ] || return 1
  for dir in "$root"/*; do
    [ -d "$dir" ] || continue
    for manifest in "$dir"/*.yaml "$dir"/*.yml; do
      [ -f "$manifest" ] || continue
      while IFS=$'\t' read -r ns name; do
        [ "$name" = "$service" ] && [ -n "$ns" ] || continue
        printf 'target\t%s\t%s\n' "$ns" "$name"
        return 0
      done < <(cw_manifest_deployments < "$manifest")
    done
  done
  return 1
}

# Map one manifest's changed lines onto its Deployment documents. Prints
# "target<TAB>namespace<TAB>name" per affected Deployment, one
# "note<TAB>whole manifest: <path>" when the lines could not be placed, in which
# case every Deployment of the manifest is a target, and one
# "note<TAB>no namespace: <name> in <path>" per affected Deployment that
# declares no metadata.namespace and is therefore skipped.
cw_place_changed_lines() {  # <path> <docs> <lines>
  CW_LINES="$3" awk -F'\t' -v path="$1" '
    BEGIN { lines = ENVIRON["CW_LINES"]; n = split(lines, l, "\n"); whole = (lines == "") }
    { start[NR] = $1; end[NR] = $2; kind[NR] = $3; ns[NR] = $4; name[NR] = $5 }
    END {
      if (!whole) {
        for (i = 1; i <= n; i++) {
          if (l[i] == "") continue
          hit = 0
          for (d = 1; d <= NR; d++) {
            if (l[i] + 0 >= start[d] && l[i] + 0 <= end[d]) {
              hit = 1
              if (kind[d] == "Deployment" && name[d] != "") pick[d] = 1
            }
          }
          if (!hit) whole = 1
        }
      }
      if (whole) for (d = 1; d <= NR; d++) if (kind[d] == "Deployment" && name[d] != "") pick[d] = 1
      for (d = 1; d <= NR; d++) {
        if (!pick[d]) continue
        if (ns[d] == "") printf "note\tno namespace: %s in %s\n", name[d], path
        else printf "target\t%s\t%s\n", ns[d], name[d]
      }
      if (whole) printf "note\twhole manifest: %s\n", path
    }
  ' <<DOCS
$2
DOCS
}

# Derive the affected Deployments from the merged PR. Prints
# "target<TAB>namespace<TAB>name" lines and "note<TAB>text" lines; prints no
# target when no deployable service is touched.
cw_derive_targets() {  # <url> <provider> <owner> <repo> <number> <repo-name>
  local url=$1 provider=$2 owner=$3 repo=$4 number=$5 repo_name=$6
  local files manifests ref changed path docs lines placed any=0 reads=0
  files=$(cw_forge_files "$url" "$provider" "$owner" "$repo" "$number") || return 1
  [ -n "$files" ] || return 1
  manifests=$(printf '%s\n' "$files" | grep -E '^k8s/prod/[^/]+/[^/]+\.ya?ml$' || true)
  if [ -z "$manifests" ]; then
    cw_app_targets "$repo_name" "$files"
    return
  fi
  ref=$(cw_forge_head_ref "$url" 2>/dev/null || true)
  changed=$(cw_forge_diff "$url" "$provider" 2>/dev/null | cw_diff_changed_lines || true)
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if printf '%s\n' "$changed" | grep -qxF "$path	removed"; then
      printf 'note\tmanifest removed: %s\n' "$path"
      continue
    fi
    if [ -z "$ref" ] || [ "$reads" -ge "$MAX_MANIFEST_READS" ]; then
      printf 'note\tmanifest unread: %s\n' "$path"
      continue
    fi
    reads=$((reads + 1))
    docs=$(cw_forge_content "$owner" "$repo" "$path" "$ref" 2>/dev/null | cw_manifest_docs) || docs=''
    if [ -z "$docs" ]; then
      printf 'note\tmanifest unread: %s\n' "$path"
      continue
    fi
    lines=$(printf '%s\n' "$changed" | awk -F'\t' -v p="$path" '$1 == p { print $2 }')
    placed=$(cw_place_changed_lines "$path" "$docs" "$lines")
    [ -n "$placed" ] || continue
    printf '%s\n' "$placed"
    case "$placed" in *target*) any=1 ;; esac
  done <<PATHS
$manifests
PATHS
  [ "$any" -eq 1 ] && return 0
  cw_app_targets "$repo_name" "$files"
}

# The service a repository-map spec names: the Deployment or image name it
# resolves to, which is also the directory a monorepo keeps that service in.
cw_spec_service() {  # <spec>
  local spec=$1
  case "$spec" in
    sentry:*|run:*|path:*|build:*) return 0 ;;
    image:*) printf '%s\n' "${spec#image:}" ;;
    */*) printf '%s\n' "${spec#*/}" ;;
    *) printf '%s\n' "$spec" ;;
  esac
}

# The path prefix a repository maps its services under, when it declares one.
cw_repo_prefix() {  # <specs>
  local spec out=''
  for spec in $1; do
    case "$spec" in path:*) out=${spec#path:} ;; esac
  done
  printf '%s\n' "$out"
}

# What a merged diff can reach in a repository, printed as one conclusion per
# line: "deployable" when any touched path is not documentation, a test, a
# script of a monorepo, or a CI file other than the repository's own deploy
# workflow; "shared"
# when it touches a deployable path no mapped service owns, because such a path
# (a root-level file, a shared library, a path under the map's path: prefix that
# names no service) is consumed by every Deployment of the repository; and
# "service <name>" per mapped service a touched path names as any of its path
# segments, so services/<name>/ and apps/<name>/ place a service the same way a
# top-level <name>/ does, or as the segment directly under the map's path:
# prefix. A diff that touches nothing but non-deployable paths prints nothing.
cw_diff_scope() {  # <files> <services> <prefix> <workflows> <multi-service>
  printf '%s\n' "$1" | CW_DIFF_SERVICES="$2" CW_DIFF_PREFIX="$3" CW_DIFF_WORKFLOWS="$4" \
    CW_DIFF_MULTI="$5" awk '
    BEGIN {
      ns = split(ENVIRON["CW_DIFF_SERVICES"], sv, " ")
      multi = ENVIRON["CW_DIFF_MULTI"]
      nw = split(ENVIRON["CW_DIFF_WORKFLOWS"], wf, " ")
      pre = ENVIRON["CW_DIFF_PREFIX"]
      sub(/\/+$/, "", pre)
    }
    {
      p = $0
      sub(/^\.\//, "", p)
      sub(/^\/+/, "", p)
      if (p == "") next
      n = split(p, part, "/")
      base = part[n]
      dep = 1
      if (part[1] == "docs" || part[1] == "doc" || part[1] == "tests" || part[1] == "test") dep = 0
      else if (multi == 1 && part[1] == "scripts") dep = 0
      else if (base ~ /\.mdx?$/) dep = 0
      else if (part[1] == ".github") {
        dep = 0
        for (i = 1; i <= nw; i++) if (wf[i] == p) dep = 1
      }
      if (!dep) next
      deployable = 1
      if (n == 1) shared = 1
      # Where the path sits relative to the map path prefix, when it declares
      # one: the segment just under the prefix names the service, and a deployable
      # path under the prefix that names no service is shared by all of them.
      inp = 0
      if (pre != "") {
        np = split(pre, pp, "/")
        inp = (n >= np)
        for (i = 1; i <= np && inp; i++) if (part[i] != pp[i]) inp = 0
      }
      if (inp) {
        svc = (n > np) ? part[np + 1] : ""
        matched = 0
        for (j = 1; j <= ns; j++)
          if (svc != "" && sv[j] == svc) { hit[j] = 1; matched = 1 }
        if (!matched) shared = 1
      } else {
        matched = 0
        for (i = 1; i <= n; i++)
          for (j = 1; j <= ns; j++)
            if (sv[j] != "" && part[i] == sv[j]) { hit[j] = 1; matched = 1 }
        if (!matched) shared = 1
      }
    }
    END {
      if (!deployable) exit 0
      printf "deployable\n"
      if (shared) printf "shared\n"
      for (j = 1; j <= ns; j++) if (hit[j]) printf "service %s\n", sv[j]
    }'
}

# An application repository's targets: its image family from the live cluster,
# its mapped Sentry project, and its mapped deploy workflow. A repository whose
# map names more than one service is a monorepo, so only the services the merged
# diff actually touches are cluster targets: a change under scripts/ deploys
# nothing and says so, instead of reporting an unproven rollout of every service
# in the map. A repository whose map names one service is that service, so any
# path the diff touches that can deploy anything is in scope, while a diff of
# documentation, tests, a monorepo's scripts, and non-deploy CI deploys nothing
# and says so too. A deployable path no service owns - a root-level file, a shared library, a
# path under the map's path: prefix - keeps every Deployment in scope rather than
# concluding clean. The Sentry project and the deploy workflow are always kept,
# because those reads never touch the cluster. Falls back to the local H-DevOps
# checkout's Deployment names when the inventory resolves no Deployment for an
# in-scope service, so a repository whose image name is unknown is still watched
# rather than silently unwatched.
cw_app_targets() {  # <repo> <files>
  local repo=$1 files=$2 specs spec service services='' scoped='' out targets nodeploy
  local touched=0 single=0 prefix workflows='' scope shared=0
  specs=$(cw_repo_specs "$repo")
  if [ -z "$specs" ]; then
    # No map entry names this repository, so it is its own single service and the
    # local H-DevOps checkout's Deployment names are the last resort.
    cw_service_targets "$repo" || true
    return 0
  fi
  prefix=$(cw_repo_prefix "$specs")
  for spec in $specs; do
    case "$spec" in
      path:*|build:*) continue ;;
      run:*)
        spec=${spec#run:}
        case "$spec" in *'#'*) workflows="$workflows ${spec#*#}" ;; esac
        continue
        ;;
      sentry:*) continue ;;
    esac
    service=$(cw_spec_service "$spec")
    [ -n "$service" ] || continue
    case " $services " in *" $service "*) ;; *) services="$services $service" ;; esac
  done
  [ "$(printf '%s' "$services" | awk '{ print NF }')" -le 1 ] && single=1
  scope=$(cw_diff_scope "$files" "${services# }" "$prefix" "${workflows# }" "$((1 - single))")
  case "$scope" in *shared*) shared=1 ;; esac
  # One service: every cluster spec is in scope as soon as the diff touches any
  # deployable path. More than one: each cluster spec is its own service and only
  # a path that names it, or one every service consumes, reaches it.
  # A diff that touches nothing deployable expects no deploy, so its deploy
  # workflow says nothing about this change: a failed or missing run is
  # not-applicable to it, never a regression or absent. Its Sentry project still
  # reads without the cluster, so it is kept.
  nodeploy=0
  case "$scope" in
    *deployable*) ;;
    *) nodeploy=1; printf 'deploy\tnone\n' ;;
  esac
  for spec in $specs; do
    case "$spec" in
      path:*|build:*) continue ;;
      run:*) [ "$nodeploy" -eq 1 ] || scoped="$scoped $spec" ;;
      sentry:*) scoped="$scoped $spec" ;;
      *)
        if [ "$single" -eq 1 ]; then
          case "$scope" in *deployable*) scoped="$scoped $spec"; touched=1 ;; esac
        elif [ "$shared" -eq 1 ] \
          || printf '%s\n' "$scope" | grep -qxF "service $(cw_spec_service "$spec")"; then
          scoped="$scoped $spec"
          touched=1
        fi
        ;;
    esac
  done
  out=''
  for spec in $scoped; do
    out="$out$(cw_spec_targets "$spec")
"
  done
  if [ "$touched" -eq 0 ]; then
    # A repository watched through its deploy workflow still measures the merge,
    # so only a kept set with no run target may say the change deploys nothing.
    printf '%s\n' "$out" | grep -q '^run	' \
      || printf 'note\tthe change deploys nothing: no Deployment path is touched by the diff\n'
    printf '%s\n' "$out" | grep -v '^target	' || true
    return 0
  fi
  targets=$(printf '%s\n' "$out" | grep -c '^target	' || true)
  if [ "$targets" -eq 0 ] && ! printf '%s\n' "$out" | grep -q '^run	'; then
    # The image inventory resolved no Deployment. Fall back to the checkout's own
    # manifest, and keep every non-Deployment target the map already resolved
    # (its Sentry project, its deploy workflow): those reads never touch the
    # cluster, so a cluster that refused the inventory is no reason to lose them.
    if cw_service_targets "$repo"; then
      printf '%s\n' "$out" | grep -v '^target	' || true
    else
      printf '%s\n' "$out"
    fi
    return 0
  fi
  printf '%s\n' "$out"
}

# --- live metric reads --------------------------------------------------------
# Each live query below is self-contained and can be run by hand with the same
# arguments, so an operator can reproduce any sample outside this script.

# --- beta stage -----------------------------------------------------------
#
# The pre-production reading of a merged change, taken before any production
# target is read. Everything here reuses the production reader, bar function, and
# rollout-fingerprint gate: the stage is a different surface and a different
# baseline, not a second measurement path.

# The home's own beta map, comments and blank lines removed.
cw_beta_map_clean() {
  sed -e 's/^#.*$//' -e 's/[[:space:]]#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    "$CW_CONFIG_DIR/change-watch-beta" 2>/dev/null | grep -v '^$' || true
}

# The beta map in force: the built-in entries, minus any key the home's own file
# names (a home line replaces the built-in line for that key), then the home's
# lines.
cw_beta_map_lines() {
  local home_keys=''
  if [ -f "$CW_CONFIG_DIR/change-watch-beta" ]; then
    home_keys=$(cw_beta_map_clean | awk 'NF >= 2 { print $1 }')
  fi
  printf '%s\n' "$CW_BETA_BUILTIN" | awk -v keys="$home_keys" '
    BEGIN { n = split(keys, k, "\n"); for (i = 1; i <= n; i++) skip[k[i]] = 1 }
    NF >= 2 && !($1 in skip)'
  [ -z "$home_keys" ] || cw_beta_map_clean
}

# The beta map as one readable phrase, so a stage that measured nothing names
# what it looked for instead of leaving a bare silence.
cw_beta_map_summary() {
  cw_beta_map_lines | awk 'NF >= 2 { printf "%s%s -> %s", sep, $1, $2; sep = ", " }'
}

# Resolve the beta targets a merged change is served by: one
# "beta<TAB>namespace<TAB>deployment<TAB>matched-path" line per beta target whose
# key matches a changed path or the repository name. A key matches a path when
# the path is the key or sits under it, so a route prefix and a repository name
# are both expressible. Two keys can name the same target, so each target is
# emitted once: it is one deployment to fingerprint, wait for, and read.
cw_beta_targets() {  # <repo-name> <files>
  local repo=$1 files=$2 key target path matched
  {
    while read -r key target; do
      [ -n "$key" ] && [ -n "$target" ] || continue
      case "$target" in */*) ;; *) continue ;; esac
      matched=''
      while IFS= read -r path; do
        [ -n "$path" ] || continue
        case "$path" in
          "$key"|"$key"/*) matched=$path; break ;;
        esac
      done <<PATHS
$files
PATHS
      if [ -z "$matched" ]; then
        [ "$repo" = "$key" ] || continue
        matched=$repo
      fi
      printf 'beta\t%s\t%s\t%s\n' "${target%%/*}" "${target#*/}" "$matched"
    done <<MAP
$(cw_beta_map_lines)
MAP
  } | awk -F'\t' '!seen[$2 "/" $3]++'
}

cw_beta_path() { printf '%s/beta\n' "$(cw_watch_dir "$1")"; }
cw_beta_landed_path() { printf '%s/beta-landed\n' "$(cw_watch_dir "$1")"; }
cw_beta_baseline_path() { printf '%s/beta-baseline\n' "$(cw_watch_dir "$1")"; }

# The beta target's pre-merge rollout fingerprint, recorded before the wait so
# the arrival of the merged sha can be proven rather than assumed. The record
# carries the same fields the production landing gate reads.
cw_beta_record_fingerprint() {  # <ns> <deploy>
  local target="$1/$2" images hashes fingerprint
  images=$(cw_pod_fact "$1" "$2" 3 2>/dev/null || true)
  hashes=$(cw_pod_fact "$1" "$2" 5 2>/dev/null || true)
  fingerprint=''
  [ -z "$images$hashes" ] || fingerprint="$images|$hashes"
  printf '%s\t%s\t%s\n' "$target" "$images" "$fingerprint"
}

# Wait, bounded, for the beta target to roll out the merged sha. Prints the
# reason and returns 1 when the rollout is not proven inside the bound, so the
# stage states an unmeasured beta instead of reading the pre-change pods.
cw_beta_await_rollout() {  # <watch-id> <ns> <deploy>
  local id=$1 ns=$2 deploy=$3 attempt=0 landed sleep_cmd recorded landed_file
  sleep_cmd=${FM_CW_SLEEP_CMD:-sleep}
  landed_file=$(cw_beta_landed_path "$id")
  while :; do
    cw_pod_facts_clear
    CW_TARGET_CARRIED_CACHE=''
    CW_TARGET_CARRIED_REASON=''
    recorded=$(awk -F'\t' -v t="$ns/$deploy" '$1 == t { print $2; exit }' "$landed_file" 2>/dev/null || true)
    if [ -z "$recorded" ]; then
      printf 'deploy landing unreadable: the beta target pod fingerprint could not be read at registration\n'
      return 1
    fi
    landed=0
    cw_target_landed "$id" "$ns" "$deploy" "$landed_file" || landed=$?
    case "$landed" in
      0) return 0 ;;
      2) ;;
      *) printf '%s\n' "${CW_TARGET_CARRIED_REASON:-deploy landing unreadable: the beta target pod fingerprint could not be read}"
         return 1 ;;
    esac
    attempt=$((attempt + 1))
    if [ "$attempt" -ge "$BETA_WAIT_ATTEMPTS" ]; then
      printf 'awaiting the deploy: the beta target still runs the pods it ran at registration after %s attempt(s)\n' \
        "$attempt"
      return 1
    fi
    "$sleep_cmd" "$BETA_POLL_SECONDS" >/dev/null 2>&1 || true
  done
}

# The beta baseline: the beta target's own pre-rollout readings, captured before
# the wait because after the rollout the pre-change state is gone. The beta
# verdict is relative to this, never to an absolute bar a dev environment was
# never held to.
cw_beta_capture_baseline() {  # <watch-id> <ns> <deploy> <since-epoch>
  local id=$1 target="$2/$3" since=$4 metric value rc err out=''
  err=$(mktemp "${TMPDIR:-/tmp}/fm-cw-bbase.XXXXXX" 2>/dev/null) || err=/dev/null
  for metric in $BETA_METRICS; do
    value=''; rc=0
    value=$(cw_metric_read "$id" "$metric" "$target" baseline "$since" 2>"$err") || rc=$?
    if [ "$rc" -ne 0 ] || ! printf '%s' "$value" | grep -qE '^-?[0-9]+([.][0-9]+)?$'; then
      value=''
    fi
    out="$out$metric@$target	$value
"
  done
  [ "$err" = /dev/null ] || rm -f -- "$err" 2>/dev/null || true
  printf '%s' "$out"
}

cw_beta_baseline_value() {  # <watch-id> <metric> <target>
  local file
  file=$(cw_beta_baseline_path "$1")
  [ -f "$file" ] || return 1
  awk -F'\t' -v k="$2@$3" '$1 == k { print $2; found = 1 } END { exit(found ? 0 : 1) }' "$file"
}

# One beta reading: every beta metric of one beta target, read through the same
# reader a sample uses and scored against the beta baseline captured before the
# rollout. A metric with no readable baseline is unmeasured rather than scored
# against an absolute bar, because an absolute bar is not evidence about the
# change. Prints
# "reading<TAB>metric<TAB>target<TAB>value<TAB>regressed<TAB>reason<TAB>baseline".
cw_beta_read() {  # <watch-id> <ns> <deploy> <since-epoch>
  local id=$1 ns=$2 deploy=$3 since=$4 target="$2/$3" metric value reason rc err regressed baseline
  err=$(mktemp "${TMPDIR:-/tmp}/fm-cw-beta.XXXXXX" 2>/dev/null) || err=/dev/null
  for metric in $BETA_METRICS; do
    value=''; reason=''; rc=0; regressed=0; baseline=''
    baseline=$(cw_beta_baseline_value "$id" "$metric" "$target" 2>/dev/null || true)
    value=$(cw_metric_read "$id" "$metric" "$target" sample "$since" 2>"$err") || rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$value" ] \
      || ! printf '%s' "$value" | grep -qE '^-?[0-9]+([.][0-9]+)?$'; then
      if [ -n "$value" ] && ! printf '%s' "$value" | grep -qE '^-?[0-9]+([.][0-9]+)?$'; then
        reason=$value
      else
        reason=$(tail -1 "$err" 2>/dev/null | cut -c1-200)
        [ -n "$reason" ] || reason="the reader returned no value (exit $rc)"
      fi
      value=''
    elif [ -z "$baseline" ]; then
      reason='no beta baseline was readable for this metric, so the reading cannot be scored against the change'
      value=''
    elif cw_beta_metric_regressed "$metric" "$value" "$baseline"; then
      regressed=1
    fi
    printf 'reading\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$metric" "$target" "$value" "$regressed" "$reason" "$baseline"
  done
  [ "$err" = /dev/null ] || rm -f -- "$err" 2>/dev/null || true
}

# The whole beta stage for one merged change: resolve the beta targets, record
# their fingerprints, capture their baseline, wait for the merged sha, read, and
# print one verdict line followed by the readings. Never reads a production
# target and never arms anything.
cw_beta_stage() {  # <watch-id> <repo-name> <url> <provider> <owner> <repo> <number> <since-epoch>
  local id=$1 repo_name=$2 url=$3 provider=$4 owner=$5 repo=$6 number=$7 since=$8
  local files resolved targets ns deploy path readings='' cluster verdict blocked metric
  local landed_rows='' baseline_rows=''
  local read_count=0 regressed_line='' unmeasured_reason='' targets_seen=''
  local gap_count=0 gap_metrics=''
  if ! files=$(cw_forge_files "$url" "$provider" "$owner" "$repo" "$number" 2>/dev/null); then
    printf 'verdict\tbeta unmeasured: the merged file list could not be read, so no beta target could be resolved\n'
    return 0
  fi
  resolved=$(cw_beta_targets "$repo_name" "$files")
  targets=$(printf '%s\n' "$resolved" | awk -F'\t' '$1 == "beta" { print $2 "\t" $3 "\t" $4 }')
  if [ -z "$targets" ]; then
    printf 'verdict\tbeta clean: nothing to measure: no changed path is served by a beta target (%s)\n' \
      "$(cw_beta_map_summary)"
    return 0
  fi
  # The stage records the beta target fingerprint and baseline, so the watch
  # directory has to exist before the first read. It is created only once a beta
  # target has resolved: a change with nothing beta-served leaves no record.
  mkdir -p "$(cw_watch_dir "$id")" 2>/dev/null || true
  chmod 0700 "$(cw_watch_dir "$id")" 2>/dev/null || true
  cw_budget_start
  cluster=$(cw_cluster_probe || true)
  CW_STAGE=beta
  # The baseline is the beta target's own pre-rollout state, so it is captured
  # before the wait: after the rollout the pre-change readings are gone.
  while IFS=$'\t' read -r ns deploy path; do
    [ -n "$ns" ] || continue
    targets_seen="$targets_seen${targets_seen:+, }$ns/$deploy"
    [ -n "$cluster" ] && continue
    landed_rows="$landed_rows$(cw_beta_record_fingerprint "$ns" "$deploy")"$'\n'
    baseline_rows="$baseline_rows$(cw_beta_capture_baseline "$id" "$ns" "$deploy" "$since")"$'\n'
  done <<TARGETS
$targets
TARGETS
  if [ -n "$landed_rows" ]; then
    printf '%s' "$landed_rows" | cw_write "$(cw_beta_landed_path "$id")"
  fi
  if [ -n "$baseline_rows" ]; then
    printf '%s' "$baseline_rows" | cw_write "$(cw_beta_baseline_path "$id")"
  fi
  # Then wait for the merged sha to reach the beta target, and only then read.
  while IFS=$'\t' read -r ns deploy path; do
    [ -n "$ns" ] || continue
    if [ -n "$cluster" ]; then
      for metric in $BETA_METRICS; do
        readings="$readings$(printf 'reading\t%s\t%s\t\t0\tcluster read failed: %s\t\n' \
          "$metric" "$ns/$deploy" "$cluster")"$'\n'
      done
      continue
    fi
    if ! blocked=$(cw_beta_await_rollout "$id" "$ns" "$deploy"); then
      for metric in $BETA_METRICS; do
        readings="$readings$(printf 'reading\t%s\t%s\t\t0\t%s\t\n' \
          "$metric" "$ns/$deploy" "$blocked")"$'\n'
      done
      continue
    fi
    readings="$readings$(cw_beta_read "$id" "$ns" "$deploy" "$since")"$'\n'
  done <<TARGETS
$targets
TARGETS
  CW_STAGE=prod
  read_count=$(printf '%s\n' "$readings" | awk -F'\t' '$1 == "reading" && $4 != "" { n++ } END { print n + 0 }')
  regressed_line=$(printf '%s\n' "$readings" | awk -F'\t' \
    '$1 == "reading" && $5 == 1 { printf "beta regressed on %s (%s vs baseline %s) at %s", $2, $4, $7, $3; exit }')
  unmeasured_reason=$(printf '%s\n' "$readings" | awk -F'\t' \
    '$1 == "reading" && $4 == "" && $6 != "" { print $6; exit }')
  gap_count=$(printf '%s\n' "$readings" | awk -F'\t' \
    '$1 == "reading" && $4 == "" { n++ } END { print n + 0 }')
  gap_metrics=$(printf '%s\n' "$readings" | awk -F'\t' \
    '$1 == "reading" && $4 == "" { printf "%s%s", (seen++ ? ", " : ""), $2 }')
  if [ -n "$regressed_line" ]; then
    verdict=$regressed_line
  elif [ "$read_count" -eq 0 ]; then
    verdict="beta unmeasured: ${unmeasured_reason:-no beta metric could be read} (targets: $targets_seen)"
  elif [ "$gap_count" -gt 0 ]; then
    # A clean verdict that hides an unscored metric is the misleading pass this
    # stage exists to prevent, so the gap is named in the verdict itself.
    verdict="beta clean: $read_count of $((read_count + gap_count)) metric(s) read on $targets_seen, none crossed its bar; unmeasured: $gap_metrics"
  else
    verdict="beta clean: $read_count metric(s) read on $targets_seen, none crossed its bar"
  fi
  printf 'verdict\t%s\n' "$verdict"
  printf '%s\n' "$readings" | grep -v '^$' || true
}

# The recorded beta verdict, or nothing when the stage never ran.
cw_beta_verdict() {  # <watch-id>
  local file
  file=$(cw_beta_path "$1")
  [ -f "$file" ] || return 0
  awk -F'\t' '$1 == "verdict" { print $2; exit }' "$file" 2>/dev/null || true
}

# One wake and one steer for a beta failure, so the lane hears about it without
# waiting for a production sample that will never run.
cw_report_beta_failure() {  # <watch-id>
  local id=$1 verdict task url metric steer send_cmd
  verdict=$(cw_beta_verdict "$id")
  case "$verdict" in beta\ regressed*) ;; *) return 0 ;; esac
  cw_mark_once "$(cw_watch_dir "$id")/beta-reported" || return 0
  task=$(cw_meta_get "$id" task || true)
  url=$(cw_meta_get "$id" pr_url || true)
  metric=$(printf '%s\n' "$verdict" | sed -n 's/^beta regressed on \([^ ]*\) .*/\1/p')
  fm_wake_append check "change-watch-$id-beta" \
    "check: change-watch $task $url beta ${metric:-metric} regressed" 2>/dev/null \
    || notice "change-watch: could not queue the beta failure wake for $url"
  steer="change-watch $url failed the beta stage: $verdict; the production watch was not armed"
  send_cmd=${FM_CW_SEND_CMD:-$FM_ROOT/bin/fm-send.sh}
  "$send_cmd" "$task" "$steer" >/dev/null 2>&1 \
    || notice "change-watch: could not steer $task about the beta failure for $url"
}

# The label selector a Deployment's own pods carry, as a comma-joined "k=v"
# list sorted by key. A Deployment's spec.selector.matchLabels is the only
# authoritative answer: assuming `app=<name>` matched nothing on every
# Deployment labelled app.kubernetes.io/name (49 of the 266 Deployments in
# production, including the three services that deliver every customer
# notification), and the empty log read that followed looked exactly like an
# unmeasured rollout. Every key of the selector is used, never a subset.
# `app=<deploy>` is the fallback only when the selector cannot be read at all.
CW_SELECTOR_CACHE=''
cw_deploy_selector() {  # <ns> <deploy>
  local ns=$1 deploy=$2 key out sel
  key="$ns/$deploy"
  while IFS=$'\t' read -r k v; do
    [ "$k" = "$key" ] || continue
    printf '%s\n' "$v"
    return 0
  done <<CACHE
$CW_SELECTOR_CACHE
CACHE
  out=''
  # A stubbed series directory stands in for every cluster read, so there is no
  # Deployment to ask.
  if [ -z "${FM_CW_CLUSTER_DIR:-}" ] && command -v kubectl >/dev/null 2>&1; then
    # shellcheck disable=SC2016  # a Go template, not a shell expansion
    out=$(cw_kubectl -n "$ns" get deployment "$deploy" \
      -o jsonpath='{range $k,$v := .spec.selector.matchLabels}{$k}={$v}{"\n"}{end}' 2>/dev/null) || out=''
  fi
  sel=$(printf '%s\n' "$out" \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' \
    | sort | paste -sd ',' -)
  [ -n "$sel" ] || sel="app=$deploy"
  CW_SELECTOR_CACHE="$CW_SELECTOR_CACHE$key	$sel
"
  printf '%s\n' "$sel"
}

# LIVE QUERY (cluster) - 5xx responses per minute for one Deployment's pods, from
# the app's own access log over the window, kept only when the HTTP/1.1 line
# count proves the probe executed. Each container's read is capped at
# LOG_TAIL_LINES lines; a container that hit the cap is rated over the span its
# lines cover, one that did not over the whole window.
cw_live_http_5xx_per_min() {  # <ns> <deploy> <window-seconds>
  local ns=$1 deploy=$2 secs=$3 out
  out=$(cw_kubectl -n "$ns" logs --tail="$LOG_TAIL_LINES" --since="${secs}s" --max-log-requests=10 \
    --prefix --timestamps -l "$(cw_deploy_selector "$ns" "$deploy")" 2>/dev/null | python3 -c '
import datetime, re, sys
window = float(sys.argv[1])
cap = int(sys.argv[2])
error_re = re.compile(r"500 Internal|\"\s5[0-9][0-9]\s")
pods = {}
for line in sys.stdin:
    line = line.rstrip("\n")
    pod = ""
    if line.startswith("["):
        end = line.find("] ")
        if end > 0:
            pod = line[1:end]
            line = line[end + 2:]
    ts, _, rest = line.partition(" ")
    try:
        t = datetime.datetime.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S")
    except ValueError:
        continue
    epoch = t.replace(tzinfo=datetime.timezone.utc).timestamp()
    p = pods.setdefault(pod, {"first": epoch, "last": epoch, "lines": 0, "http": 0, "errors": 0})
    p["first"] = min(p["first"], epoch)
    p["last"] = max(p["last"], epoch)
    p["lines"] += 1
    if "HTTP/1.1" in rest:
        p["http"] += 1
    if error_re.search(rest):
        p["errors"] += 1
if sum(p["http"] for p in pods.values()) == 0:
    sys.exit(1)
rate = 0.0
for p in pods.values():
    span = window if p["lines"] < cap else max(p["last"] - p["first"], 1.0)
    rate += p["errors"] * 60.0 / span
print("%.4f" % rate)
' "$secs" "$LOG_TAIL_LINES" 2>/dev/null)
  [ -n "$out" ] || {
    printf 'no HTTP access-log status lines in this Deployment\047s pod logs over the window\n' >&2
    return 1
  }
  printf '%s\n' "$out"
}

# LIVE QUERY (cluster) - one Deployment's pod facts, read once and reused by
# every metric that needs them: restartCount total, the OOMKilled termination
# epochs, the pod images, and the per-container memory limits that the
# working-set ratio divides by, and the pods' pod-template-hash labels that the
# landing gate uses to prove a rollout. The row is epoch-free so one read answers
# the landing gate and every pod-backed metric of the sample; cw_prime_pod_facts
# takes that read in this process, because a memo written inside a per-metric
# command substitution dies with its subshell. Prints
# "restarts<TAB>oom-epochs<TAB>images<TAB>pairs<TAB>hashes" where oom-epochs is
# the termination epochs joined by "," (0 for a termination that carries no
# timestamp), pairs is "pod,container,limit-bytes" joined by ";", and hashes is
# the sorted distinct pod-template-hash values joined by ",".
CW_POD_FACTS_CACHE=''
CW_WORKLOADS_CACHE=''
# A read that failed is remembered for the sample as this sentinel, so a target
# whose pods cannot be read costs one attempt instead of one per metric.
CW_POD_FACTS_FAILED='!'
# Forget every pod read in this process. The beta stage re-reads the same
# target's fingerprint until the rollout lands, and the memo would otherwise
# answer with the read taken before the deploy.
cw_pod_facts_clear() { CW_POD_FACTS_CACHE=''; }

cw_pod_facts_failed() {  # <key>
  CW_POD_FACTS_CACHE="$CW_POD_FACTS_CACHE$1	$CW_POD_FACTS_FAILED
"
}
cw_pod_facts() {  # <ns> <deploy>
  local ns=$1 deploy=$2 key cached
  key="$ns/$deploy"
  while IFS=$'\t' read -r k v; do
    [ "$k" = "$key" ] || continue
    [ "$v" = "$CW_POD_FACTS_FAILED" ] && return 1
    printf '%s\n' "$v"
    return 0
  done <<CACHE
$CW_POD_FACTS_CACHE
CACHE
  command -v kubectl >/dev/null 2>&1 || { cw_pod_facts_failed "$key"; return 1; }
  cached=$(cw_kubectl -n "$ns" get pods -l "$(cw_deploy_selector "$ns" "$deploy")" -o json 2>/dev/null | python3 -c '
import datetime, json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
items = data.get("items", [])
if not items:
    sys.exit(1)
restarts = 0
ooms = []
images = []
hashes = []
pairs = []
for pod in items:
    pname = pod.get("metadata", {}).get("name", "")
    h = (pod.get("metadata", {}).get("labels", {}) or {}).get("pod-template-hash", "")
    if h and h not in hashes:
        hashes.append(h)
    for cs in pod.get("status", {}).get("containerStatuses", []) or []:
        restarts += int(cs.get("restartCount", 0) or 0)
        for state in (cs.get("lastState", {}) or {}).values():
            if not isinstance(state, dict) or state.get("reason") != "OOMKilled":
                continue
            ts = state.get("finishedAt") or ""
            try:
                t = datetime.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ")
                ooms.append(int(t.replace(tzinfo=datetime.timezone.utc).timestamp()))
            except ValueError:
                ooms.append(0)
    for c in pod.get("spec", {}).get("containers", []) or []:
        img = c.get("image", "")
        if img and img not in images:
            images.append(img)
        raw = str((c.get("resources", {}).get("limits", {}) or {}).get("memory", "") or "")
        factor = 1
        for suffix, mult in (("Ki", 1024), ("Mi", 1024 ** 2), ("Gi", 1024 ** 3),
                             ("K", 1000), ("M", 1000 ** 2), ("G", 1000 ** 3)):
            if raw.endswith(suffix):
                factor = mult
                raw = raw[: -len(suffix)]
                break
        try:
            limit = float(raw) * factor
        except ValueError:
            limit = 0.0
        if limit > 0:
            pairs.append("%s,%s,%.0f" % (pname, c.get("name", ""), limit))
print("%d\t%s\t%s\t%s\t%s" % (restarts, ",".join(str(e) for e in ooms),
                              ",".join(images), ";".join(pairs), ",".join(hashes)))
') || { cw_pod_facts_failed "$key"; return 1; }
  [ -n "$cached" ] || { cw_pod_facts_failed "$key"; return 1; }
  CW_POD_FACTS_CACHE="$CW_POD_FACTS_CACHE$key	$cached
"
  printf '%s\n' "$cached"
}

# Read every target's pod facts once per sample so the landing gate and each
# pod-backed metric are served by that one read: a whole image family then costs
# one pod read per target instead of one per metric per target.
cw_prime_pod_facts() {  # <watch-id>
  local id=$1 ns deploy
  [ -f "$(cw_targets_path "$id")" ] || return 0
  while IFS=$'\t' read -r ns deploy; do
    [ -n "${ns:-}" ] || continue
    cw_within_budget || return 0
    cw_pod_facts "$ns" "$deploy" >/dev/null 2>&1 || true
  done < "$(cw_targets_path "$id")"
}

# Resolve the watched merge's sha once per sample, in this process, so the
# deploy-workflow reads that follow inherit it instead of each spending its own
# forge call on the same merge.
cw_prime_merge_sha() {  # <watch-id>
  local id=$1
  # A deploy-workflow read needs the sha, and so does a landing gate that maps a
  # running image to its commit through a build: spec.
  [ -s "$(cw_runs_path "$id")" ] \
    || cw_repo_build_spec "$(cw_meta_get "$id" repo 2>/dev/null || true)" >/dev/null 2>&1 \
    || return 0
  cw_merge_sha "$id" >/dev/null 2>&1 || true
}

# Read every target's own label selector once per sample, in this process, so
# each metric's subshell inherits it instead of spending one cluster read per
# metric on the same Deployment.
cw_prime_selectors() {  # <watch-id>
  local id=$1 ns deploy
  [ -f "$(cw_targets_path "$id")" ] || return 0
  while IFS=$'\t' read -r ns deploy; do
    [ -n "${ns:-}" ] || continue
    cw_within_budget || return 0
    cw_deploy_selector "$ns" "$deploy" >/dev/null 2>&1 || true
  done < "$(cw_targets_path "$id")"
}

# One field of a target's pod facts, or nothing when the read failed.
cw_pod_fact() {  # <ns> <deploy> <field>
  local facts
  facts=$(cw_pod_facts "$1" "$2") || return 1
  printf '%s' "$facts" | cut -f"$3"
}

# LIVE QUERY (cluster) - total container restartCount across the Deployment.
cw_live_restarts() {  # <ns> <deploy>
  cw_pod_fact "$1" "$2" 1
}

# LIVE QUERY (cluster) - OOMKilled terminations at or after the baseline epoch.
# An OOMKilled pod that restarted successfully never shows in the pod's current
# STATUS, so lastState is the only honest signal. A termination that carries no
# timestamp cannot be proven to predate the baseline, so it counts.
cw_live_oomkilled() {  # <ns> <deploy> <baseline-epoch>
  local epochs
  epochs=$(cw_pod_fact "$1" "$2" 2) || return 1
  printf '%s' "$epochs" | awk -F, -v since="${3:-0}" '
    { for (i = 1; i <= NF; i++) if ($i != "" && ($i + 0 == 0 || $i + 0 >= since)) n++ }
    END { print n + 0 }
  '
}

# LIVE QUERY (cluster) - the pod images a target runs, comma-separated.
cw_live_images() {  # <ns> <deploy>
  cw_pod_fact "$1" "$2" 3
}

# LIVE QUERY (cluster) - the rollout fingerprint a target is judged by: its pod
# images plus its pods' pod-template-hash labels. A Deployment rollout always
# mints a new template hash, so an env or routing change that leaves every image
# byte-identical still changes the fingerprint, while a mutable tag or a
# digest-pinned reference still proves the rollout happened by its own hash.
cw_live_fingerprint() {  # <ns> <deploy>
  local facts images hashes
  facts=$(cw_pod_facts "$1" "$2") || return 1
  images=$(printf '%s' "$facts" | cut -f3)
  hashes=$(printf '%s' "$facts" | cut -f5)
  [ -n "$images$hashes" ] || return 1
  printf '%s|%s\n' "$images" "$hashes"
}

# LIVE QUERY (cluster) - request p95 latency where the service exposes it, from
# the conventional per-service Prometheus histogram. An absent series is
# unmeasured, not a pass. The read needs a port-forward into the monitoring
# namespace, which a read-only reader is usually not granted; that refusal is a
# measured gap with its reason recorded, never a silent zero.
cw_live_p95_ms() {  # <ns> <deploy> <window-seconds>
  local ns=$1 deploy=$2 secs=$3 value rc
  command -v kubectl >/dev/null 2>&1 || return 1
  command -v curl >/dev/null 2>&1 || return 1
  fm_run_timed "$(cw_budget_left || printf 5)" kubectl -n monitoring \
    auth can-i create pods/portforward >/dev/null 2>&1 || {
    printf 'port-forward into the monitoring namespace is not permitted for this reader, so the Prometheus p95 series cannot be read\n' >&2
    return 1
  }
  value=$(
    cw_kubectl -n monitoring port-forward svc/kube-prometheus-kube-prome-prometheus 19090:9090 >/dev/null 2>&1 &
    pf=$!
    sleep 1
    curl -fsS -G 'http://127.0.0.1:19090/api/v1/query' \
      --data-urlencode "query=histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket{namespace=\"$ns\",app=\"$deploy\"}[${secs}s])) by (le))" \
      2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    print(float(data["data"]["result"][0]["value"][1]) * 1000)
except Exception:
    sys.exit(1)
' 2>/dev/null
    rc=$?
    kill "$pf" 2>/dev/null || true
    exit "$rc"
  )
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

# LIVE QUERY (cluster) - highest container working set as a fraction of its
# memory limit across the Deployment's pods. The limits come from the pod facts
# read the other pod metrics already share, and the working set from
# metrics-server (POD NAME CONTAINER CPU MEMORY); the worst ratio wins.
cw_live_rss_ratio() {  # <ns> <deploy> <window-seconds>
  local ns=$1 deploy=$2 limits usage
  limits=$(cw_pod_fact "$1" "$2" 4) || return 1
  [ -n "$limits" ] || return 1
  usage=$(cw_kubectl -n "$ns" top pods -l "$(cw_deploy_selector "$ns" "$deploy")" --containers --no-headers 2>/dev/null) || return 1
  [ -n "$usage" ] || return 1
  printf '%s\n' "$limits" | tr ';' '\n' | CW_USAGE="$usage" awk -F',' '
    function bytes(u,    two, one) {
      two = substr(u, length(u) - 1, 2)
      one = substr(u, length(u), 1)
      if (two == "Ki") return substr(u, 1, length(u) - 2) * 1024
      if (two == "Mi") return substr(u, 1, length(u) - 2) * 1048576
      if (two == "Gi") return substr(u, 1, length(u) - 2) * 1073741824
      if (one == "K") return substr(u, 1, length(u) - 1) * 1000
      if (one == "M") return substr(u, 1, length(u) - 1) * 1000000
      if (one == "G") return substr(u, 1, length(u) - 1) * 1000000000
      return u + 0
    }
    BEGIN {
      n = split(ENVIRON["CW_USAGE"], rows, "\n")
      for (i = 1; i <= n; i++) {
        m = split(rows[i], f, /[ \t]+/)
        if (m < 4) continue
        used[f[1] SUBSEP f[2]] = bytes(f[4])
      }
      worst = 0
    }
    {
      key = $1 SUBSEP $2
      if (key in used && $3 + 0 > 0) {
        r = used[key] / ($3 + 0)
        if (r > worst) worst = r
      }
    }
    END { if (worst > 0) printf "%.4f\n", worst }
  '
}

# LIVE QUERY (http) - the mapped Sentry project's new error and fatal issues:
# those first seen at or after <since-epoch>. A missing credential, an unmapped
# project, or a refused read is unmeasured with its reason, never a zero.

# True when the vault holds a token, without ever materialising the token itself.
cw_sentry_vault_ready() {
  local file=$SENTRY_VAULT
  [ -r "$file" ] || return 1
  python3 - "$file" <<'PY' 2>/dev/null || return 1
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
inner = data.get("data") if isinstance(data, dict) else None
if not isinstance(inner, dict) or not (inner.get("auth_token") or ""):
    sys.exit(1)
PY
}

# One page of the mapped project's issues first seen at or after <since>, as the
# JSON its caller counts. The filter is server-side so a busy project's newest
# issues are the page itself rather than whatever survived a most-recently-seen
# cut, and the token is read and used inside the interpreter only: unlike a curl
# header built from it, it never appears in any process's argv.
cw_sentry_issue_page() {  # <project> <since-epoch>
  local project=$1 since=$2 budget
  if [ -n "${FM_CW_SENTRY_DIR:-}" ]; then
    [ -f "$FM_CW_SENTRY_DIR/issues-$project.json" ] || return 1
    cat "$FM_CW_SENTRY_DIR/issues-$project.json"
    return 0
  fi
  command -v python3 >/dev/null 2>&1 || return 1
  budget=$(cw_budget_left || printf '%s' "$SENTRY_HTTP_TIMEOUT")
  fm_run_timed "$budget" python3 -c '
import datetime, json, sys, urllib.error, urllib.parse, urllib.request
vault, project, since, timeout = sys.argv[1], sys.argv[2], int(sys.argv[3]), float(sys.argv[4])
try:
    data = json.load(open(vault))
except Exception:
    sys.stderr.write("no readable Sentry vault at %s\n" % vault)
    sys.exit(1)
inner = data.get("data") if isinstance(data, dict) else None
if not isinstance(inner, dict):
    sys.stderr.write("Sentry vault %s has no data section\n" % vault)
    sys.exit(1)
token = inner.get("auth_token") or ""
if not token:
    sys.stderr.write("no Sentry token in %s\n" % vault)
    sys.exit(1)
host = inner.get("host") or "sentry.io"
org = inner.get("org") or "musoai"
first_seen = datetime.datetime.fromtimestamp(since, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")
params = urllib.parse.urlencode({
    "query": "is:unresolved firstSeen:>=%s" % first_seen,
    "limit": "100",
    "sort": "new",
})
url = "https://%s/api/0/projects/%s/%s/issues/?%s" % (host, org, project, params)
request = urllib.request.Request(url, headers={"Authorization": "Bearer %s" % token})
try:
    with urllib.request.urlopen(request, timeout=timeout) as response:
        body = response.read()
except urllib.error.HTTPError as exc:
    sys.stderr.write("Sentry read refused for %s: HTTP %s\n" % (project, exc.code))
    sys.exit(1)
except Exception as exc:
    sys.stderr.write("Sentry read refused for %s: %s\n" % (project, exc))
    sys.exit(1)
try:
    issues = json.loads(body)
except ValueError:
    issues = None
if not isinstance(issues, list):
    sys.stderr.write("Sentry returned an unreadable issue list for %s\n" % project)
    sys.exit(1)
json.dump(issues, sys.stdout)
' "$SENTRY_VAULT" "$project" "$since" "$SENTRY_HTTP_TIMEOUT"
}

cw_live_sentry_new_issues() {  # <project> <since-epoch>
  local project=$1 since=$2 page
  case "$project" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  page=$(cw_sentry_issue_page "$project" "$since") || return 1
  printf '%s' "$page" | python3 -c '
import datetime, json, sys
since = int(sys.argv[1] or 0)
try:
    issues = json.load(sys.stdin)
except Exception:
    sys.exit(1)
if not isinstance(issues, list):
    sys.exit(1)
count = 0
for issue in issues:
    level = (issue.get("level") or "").lower()
    if level not in ("error", "fatal"):
        continue
    first = issue.get("firstSeen") or ""
    try:
        t = datetime.datetime.strptime(first.replace("Z", "")[:19], "%Y-%m-%dT%H:%M:%S")
    except ValueError:
        continue
    if int(t.replace(tzinfo=datetime.timezone.utc).timestamp()) >= since:
        count += 1
print(count)
' "$since"
}

# LIVE QUERY (forge) - the mapped deploy workflow's run created at or after the
# merge: 1 when the latest run whose tree carries the merge completed
# successfully, 0 when that run failed, and nothing while no run exists or one is
# still in flight (both are awaiting the deploy, never health), and so is a
# containment read that failed or was cut, because an unreadable answer cannot say
# the tree lacks the merge. The latest carrier decides, not the first: a deploy
# that failed and was retried successfully has
# landed, while one that succeeded and was then retried into a failure has not.
# With no merge sha to check carriers against, no run
# can be attributed to this release, so none is scored: an unrelated run is
# neither this release's success nor its regression, and scoring it either way
# would invent a verdict from a run whose tree never carried the commit.
cw_live_deploy_run() {  # <owner/repo> <workflow> <since-epoch> [<merge-sha>]
  local repo=$1 workflow=$2 since=$3 sha=${4:-}
  local gh_cmd=${FM_CW_GH:-gh} out rc=0 cands created runsha status conclusion carried=''
  local carried_status='' carried_conclusion='' deadline='' cap crc=0 unreadable=''
  if [ -n "$CW_BUDGET_START" ]; then
    deadline=$(( CW_BUDGET_START + SAMPLE_DEADLINE_SECONDS ))
    cap=$(( $(cw_now) + FORGE_TIMEOUT ))
    if [ "$cap" -lt "$deadline" ]; then deadline=$cap; fi
  fi
  if [ -n "${FM_CW_GH_DIR:-}" ]; then
    local safe=${workflow//[\/ ]/_}
    [ -f "$FM_CW_GH_DIR/runs-$repo-$safe.json" ] || {
      printf 'awaiting the deploy: no %s run since the merge\n' "$workflow"
      return 1
    }
    out=$(cat "$FM_CW_GH_DIR/runs-$repo-$safe.json")
  else
    command -v "$gh_cmd" >/dev/null 2>&1 || return 1
    # headSha is asked for by name: the run that says anything about this release
    # is the one whose tree carries the merged commit. hydra deploys from its own
    # daily schedule and a manual dispatch, never a push, so the earliest run
    # created after a merge can belong to an older tip - reading that one as 0
    # reported six healthy releases as regressions. Several runs can also carry the
    # merge itself, and then the latest one decides: a deploy that failed and was
    # retried successfully has landed, so stopping at the first carrier it found
    # called a retry that had already succeeded a regression forever (hydra#2233,
    # failed 14:12:47Z and succeeded 14:34:56Z on the same sha, still scored 0 by a
    # reading taken at 14:42:09Z).
    out=$(cw_forge_run "$gh_cmd" run list -R "$repo" --workflow "$workflow" --limit 20 \
      --json conclusion,status,createdAt,databaseId,url,headSha) || rc=$?
    if [ "${rc:-0}" -ne 0 ]; then
      # A spent budget is stated as itself: "read exited 124 with no value" told
      # nobody why the deploy target stayed unmeasured.
      [ "${rc:-0}" -ne 124 ] || printf 'the forge read budget for this sample was already spent\n'
      return 1
    fi
  fi
  cands=$(printf '%s' "$out" | python3 -c '
import datetime, json, sys
since = int(sys.argv[1] or 0)
try:
    runs = json.load(sys.stdin)
except Exception:
    sys.exit(2)
if not isinstance(runs, list):
    sys.exit(2)
candidates = []
for run in runs:
    created = run.get("createdAt") or ""
    try:
        t = datetime.datetime.strptime(created.replace("Z", "")[:19], "%Y-%m-%dT%H:%M:%S")
    except ValueError:
        continue
    if int(t.replace(tzinfo=datetime.timezone.utc).timestamp()) >= since:
        candidates.append(run)
candidates.sort(key=lambda r: r.get("createdAt") or "")
for run in candidates:
    print("\t".join([
        run.get("createdAt") or "-",
        # A placeholder, never an empty field: read(1) collapses adjacent tabs.
        run.get("headSha") or "-",
        run.get("status") or "-",
        run.get("conclusion") or "-",
    ]))
' "$since") || return 1
  if [ -z "$cands" ]; then
    printf 'awaiting the deploy: no %s run since the merge\n' "$workflow"
    return 1
  fi
  if [ -z "$sha" ]; then
    printf 'awaiting the deploy: merge sha unreadable, so no %s run can be proven to carry it\n' "$workflow"
    return 1
  fi
  while IFS=$'\t' read -r created runsha status conclusion; do
    [ -n "$created" ] || continue
    # "-" is the reader's placeholder for a field the run does not carry.
    if [ "$runsha" = "-" ]; then runsha=''; fi
    if [ "$status" = "-" ]; then status=''; fi
    if [ "$conclusion" = "-" ]; then conclusion=''; fi
    if [ "$runsha" != "$sha" ]; then
      crc=0
      cw_forge_run_carries "$repo" "$sha" "$runsha" "$deadline" || crc=$?
      case "$crc" in
        0) ;;
        1) continue ;;
        *) unreadable=1
           continue ;;
      esac
    fi
    # Cands are sorted oldest first, so the last carrier seen is the latest one and
    # it is the one that decides; an earlier failure stays visible in the history
    # without becoming the verdict.
    carried=1
    carried_status=$status
    carried_conclusion=$conclusion
    unreadable=''
  done <<CANDIDATES
$cands
CANDIDATES
  if [ -n "$unreadable" ]; then
    printf 'awaiting the deploy: whether the %s run carries %s could not be read\n' \
      "$workflow" "${sha:0:8}"
    return 1
  fi
  if [ -z "$carried" ]; then
    printf 'awaiting the deploy: no %s run carrying %s yet\n' "$workflow" "${sha:0:8}"
    return 1
  fi
  # A run still going is a deploy that has not landed yet, not a measurement gap:
  # hydra's deploy takes 17-20 minutes, so the +15m reading of every merge only
  # ever sees it in flight.
  if [ "$carried_status" != completed ] || [ -z "$carried_conclusion" ]; then
    printf 'awaiting the deploy: the %s run is %s\n' "$workflow" "${carried_status:-unknown}"
    return 1
  fi
  if [ "$carried_conclusion" = success ]; then
    printf '1\n'
    return 0
  fi
  printf '0\n'
  return 0
}

# LIVE QUERY (cluster) - the Deployment's own pgbouncer pool as
# "ip<TAB>port<TAB>database": DB_HOST/DB_PORT/DB_NAME from the pod spec with
# secret refs resolved, and the pooler endpoint behind that Service from its
# EndpointSlice. Prints nothing when any step is unresolvable.
cw_live_pool_spec() {  # <ns> <deploy>
  local ns=$1 deploy=$2 env host port db svc rest sns endpoint
  env=$(cw_kubectl -n "$ns" set env "deployment/$deploy" --list --resolve 2>/dev/null) || return 1
  host=$(printf '%s\n' "$env" | awk -F= '$1 == "DB_HOST" { print $2; exit }')
  port=$(printf '%s\n' "$env" | awk -F= '$1 == "DB_PORT" { print $2; exit }')
  db=$(printf '%s\n' "$env" | awk -F= '$1 == "DB_NAME" { print $2; exit }')
  [ -n "$host" ] && [ -n "$db" ] || return 1
  case "$port" in ''|*[!0-9]*) port=5432 ;; esac
  case "$db" in *[!A-Za-z0-9_-]*) return 1 ;; esac
  case "$host" in
    *[!0-9.]*)
      svc=${host%%.*}
      rest=${host#*.}
      sns=${rest%%.*}
      [ -n "$svc" ] && [ -n "$sns" ] && [ "$rest" != "$host" ] || return 1
      endpoint=$(cw_kubectl -n "$sns" get endpointslices -l "kubernetes.io/service-name=$svc" -o json 2>/dev/null \
        | python3 -c '
import json, sys
want = int(sys.argv[1])
data = json.load(sys.stdin)
for item in data.get("items", []):
    ports = [int(p["port"]) for p in item.get("ports", []) or [] if p.get("port")]
    if not ports:
        continue
    port = want if want in ports else ports[0]
    for ep in item.get("endpoints", []) or []:
        for addr in ep.get("addresses", []) or []:
            print("%s\t%s" % (addr, port))
            sys.exit(0)
sys.exit(1)
' "$port" 2>/dev/null) || return 1
      ;;
    *) endpoint=$(printf '%s\t%s' "$host" "$port") ;;
  esac
  [ -n "$endpoint" ] || return 1
  printf '%s\t%s\n' "$endpoint" "$db"
}

# LIVE QUERY (pooler host) - the pgbouncer admin console's SHOW POOLS on the
# pooler at <host>, reached as ubuntu over ssh with stdin closed (so the read
# can never drain a caller's input stream), through the admin unix socket, and
# bounded by the remaining sample budget. Prints the console's unaligned rows;
# exit 124 when the bound was hit.
# A host whose console did not answer is remembered for this sample: a watch
# with several targets on one unreachable pooler must not spend the sample budget
# on the same connect timeout once per target. The record is a file because every
# pool read runs inside a command substitution, where a variable assignment dies
# with its subshell.
# The path is made once per process with mktemp so no other process can
# pre-place it, and it is unlinked when the process exits.
CW_POOL_BAD_HOSTS_FILE=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-cw-pool-unreachable.XXXXXX" 2>/dev/null) || CW_POOL_BAD_HOSTS_FILE=''
cw_pool_memo_clear() {
  [ -z "$CW_POOL_BAD_HOSTS_FILE" ] || rm -f -- "$CW_POOL_BAD_HOSTS_FILE" 2>/dev/null || true
}
cw_pool_console() {  # <host> <port>
  local host=$1 port=$2 left out rc
  command -v ssh >/dev/null 2>&1 || return 1
  case "$port" in ''|*[!0-9]*) return 1 ;; esac
  case "$host" in ''|*[!A-Za-z0-9.-]*) return 1 ;; esac
  if [ -n "$CW_POOL_BAD_HOSTS_FILE" ] && grep -qxF -- "$host" "$CW_POOL_BAD_HOSTS_FILE" 2>/dev/null; then
    printf '%s: console unreachable (recorded earlier in this read)\n' "$host" >&2
    return 1
  fi
  left=$(cw_budget_left) || return 124
  out=$(fm_run_timed "$left" ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
    "$POOLER_SSH_USER@$host" \
    "sudo -u postgres psql -h $POOLER_SOCKET_DIR -p $port -U pgbouncer pgbouncer -Ac 'SHOW POOLS'")
  rc=$?
  if [ "$rc" -ne 0 ]; then
    [ -z "$CW_POOL_BAD_HOSTS_FILE" ] \
      || printf '%s\n' "$host" >> "$CW_POOL_BAD_HOSTS_FILE" 2>/dev/null || true
    return "$rc"
  fi
  printf '%s\n' "$out"
}

# Clients waiting on one database's pools (cl_waiting summed over that
# database's users). An unreachable console or an absent database is unmeasured.
cw_live_pgbouncer_cl_waiting() {  # <host> <port> <database>
  local host=$1 port=$2 db=$3 out err rc
  case "$db" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
  err=$(mktemp "${TMPDIR:-/tmp}/fm-cw-pool.XXXXXX" 2>/dev/null) || err=/dev/null
  out=$(cw_pool_console "$host" "$port" 2>"$err")
  rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    printf 'pgbouncer console %s:%s unreachable: %s\n' "$host" "$port" \
      "$(tail -1 "$err" 2>/dev/null || printf 'exit %s with no rows' "$rc")" >&2
    [ "$err" = /dev/null ] || rm -f -- "$err"
    return 1
  fi
  [ "$err" = /dev/null ] || rm -f -- "$err"
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | awk -F'|' -v db="$db" '
    NR == 1 {
      for (i = 1; i <= NF; i++) { if ($i == "database") d = i; if ($i == "cl_waiting") w = i }
      next
    }
    d && w && $d == db { sum += $w + 0; found = 1 }
    END { if (!found) exit 1; printf "%.0f\n", sum }
  '
}

# Resolve one target's pool through the test seam or the live query.
cw_resolve_pool_spec() {  # <ns> <deploy>
  local file
  if [ -n "${FM_CW_CLUSTER_DIR:-}" ]; then
    file="$FM_CW_CLUSTER_DIR/pool.$(printf '%s_%s' "$1" "$2")"
    [ -f "$file" ] || return 1
    head -1 "$file"
    return 0
  fi
  cw_live_pool_spec "$1" "$2"
}

cw_pool_spec() {  # <watch-id> <target>
  local file
  file=$(cw_pools_path "$1")
  [ -f "$file" ] || return 1
  awk -F'\t' -v t="$2" '$1 == t && $2 != "" { print $2 "\t" $3 "\t" $4; found = 1; exit } END { exit(found ? 0 : 1) }' "$file"
}

# Dispatch one metric read through the test seam or its live function.
cw_metric_read() {  # <watch-id> <metric> <target> <window> [<baseline-epoch>]
  local id=$1 metric=$2 target=$3 window=$4 since=${5:-0}
  local file value sanitized secs ns='' deploy='' spec=''
  cw_trace "$metric" "$target"
  if [ "$metric" = pgbouncer_cl_waiting ]; then
    if ! spec=$(cw_pool_spec "$id" "$target"); then
      printf 'no pgbouncer pool was resolved for this target, so its pool metric is unmeasured for the whole watch\n' >&2
      return 1
    fi
  fi
  if [ -n "${FM_CW_CLUSTER_DIR:-}" ]; then
    sanitized=$(printf '%s' "$target" | tr '/' '_')
    file="$FM_CW_CLUSTER_DIR/$metric.$sanitized.$window"
    [ -f "$file" ] || return 1
    value=$(cw_series_next "$file" "$metric.$sanitized.$window")
    case "$value" in
      '') return 1 ;;
      *) printf '%s\n' "$value"; return 0 ;;
    esac
  fi
  case "$metric" in
    sentry_new_issues)
      cw_live_sentry_new_issues "${target#sentry/}" "$since"
      return $?
      ;;
    deploy_run)
      local run_target=${target#run/}
      cw_live_deploy_run "${run_target%%#*}" "${run_target#*#}" "$since" "$(cw_merge_sha "$id")"
      return $?
      ;;
  esac
  case "$target" in
    */*) ns=${target%%/*}; deploy=${target#*/} ;;
    *) return 1 ;;
  esac
  if [ "$window" = baseline ]; then secs=$BASELINE_WINDOW_SECONDS; else secs=$SAMPLE_WINDOW_SECONDS; fi
  case "$metric" in
    http_5xx_per_min) cw_live_http_5xx_per_min "$ns" "$deploy" "$secs" ;;
    restarts) cw_live_restarts "$ns" "$deploy" ;;
    oomkilled) cw_live_oomkilled "$ns" "$deploy" "$since" ;;
    p95_ms) cw_live_p95_ms "$ns" "$deploy" "$secs" ;;
    rss_ratio) cw_live_rss_ratio "$ns" "$deploy" "$secs" ;;
    pgbouncer_cl_waiting)
      cw_live_pgbouncer_cl_waiting "$(printf '%s' "$spec" | cut -f1)" \
        "$(printf '%s' "$spec" | cut -f2)" "$(printf '%s' "$spec" | cut -f3)"
      ;;
    *) return 1 ;;
  esac
}

# Read the next value from a stub series, consuming it through a durable cursor.
cw_series_next() {  # <file> <cursor-id>
  local file=$1 id=$2 cursor_file total next
  mkdir -p "$WATCH_ROOT" 2>/dev/null || true
  cursor_file="$WATCH_ROOT/.series-cursor.$id"
  total=$(grep -c '' "$file" 2>/dev/null || echo 0)
  next=$(( $(cat "$cursor_file" 2>/dev/null || echo 0) + 1 ))
  printf '%s\n' "$next" > "$cursor_file" 2>/dev/null || true
  [ "$next" -le "$total" ] || return 1
  sed -n "${next}p" "$file"
}

# --- baseline and sample ------------------------------------------------------

cw_metric_keys() {  # <watch-id>
  local id=$1 target ns deploy metric project run_repo workflow
  if [ -f "$(cw_targets_path "$id")" ]; then
    while IFS=$'\t' read -r ns deploy; do
      [ -n "${ns:-}" ] || continue
      target="$ns/$deploy"
      for metric in $K8S_METRICS; do
        printf '%s@%s\n' "$metric" "$target"
      done
    done < "$(cw_targets_path "$id")"
  fi
  if [ -f "$(cw_sentry_path "$id")" ]; then
    while IFS= read -r project; do
      [ -n "$project" ] || continue
      for metric in $SENTRY_METRICS; do
        printf '%s@sentry/%s\n' "$metric" "$project"
      done
    done < "$(cw_sentry_path "$id")"
  fi
  if [ -f "$(cw_runs_path "$id")" ]; then
    while IFS=$'\t' read -r run_repo workflow; do
      [ -n "${run_repo:-}" ] || continue
      for metric in $RUN_METRICS; do
        printf '%s@run/%s#%s\n' "$metric" "$run_repo" "$workflow"
      done
    done < "$(cw_runs_path "$id")"
  fi
}

# Every target of every kind this watch was registered with, as the target
# strings the metric keys carry, so a completion can name what it never read.
cw_target_ids() {  # <watch-id>
  local id=$1 ns deploy project run_repo workflow
  if [ -f "$(cw_targets_path "$id")" ]; then
    while IFS=$'\t' read -r ns deploy; do
      [ -n "${ns:-}" ] || continue
      printf '%s/%s\n' "$ns" "$deploy"
    done < "$(cw_targets_path "$id")"
  fi
  if [ -f "$(cw_sentry_path "$id")" ]; then
    while IFS= read -r project; do
      [ -n "$project" ] || continue
      printf 'sentry/%s\n' "$project"
    done < "$(cw_sentry_path "$id")"
  fi
  if [ -f "$(cw_runs_path "$id")" ]; then
    while IFS=$'\t' read -r run_repo workflow; do
      [ -n "${run_repo:-}" ] || continue
      printf 'run/%s#%s\n' "$run_repo" "$workflow"
    done < "$(cw_runs_path "$id")"
  fi
}

# Whether the image a target runs right now was already built from a tree that
# carries the merge, through the repository's build: spec. 0 = carried (prints
# "<tag> built from <sha8>"), 1 = not carried or nothing maps the image, 3 = the
# build commit or its history could not be read. A tag's build commit and its
# containment never change, so both answers are remembered in the watch's builds
# file and cost one forge read per tag per watch; an unreadable answer is not
# remembered there, so the next sample asks again, and is remembered for the
# target for the rest of this sample so one sample reads it once.
CW_TARGET_CARRIED_EVIDENCE=''
CW_TARGET_CARRIED_REASON=''
cw_target_carries_merge() {  # <watch-id> <ns> <deploy>
  local id=$1 ns=$2 deploy=$3 repo owner spec build_repo workflow image_name
  local images img ref tag='' number cache row sha state merge deadline='' cap
  CW_TARGET_CARRIED_EVIDENCE=''
  CW_TARGET_CARRIED_REASON=''
  repo=$(cw_meta_get "$id" repo 2>/dev/null || true)
  owner=$(cw_meta_get "$id" owner 2>/dev/null || true)
  [ -n "$repo" ] && [ -n "$owner" ] || return 1
  spec=$(cw_repo_build_spec "$repo") || return 1
  build_repo=$(printf '%s' "$spec" | cut -f1)
  workflow=$(printf '%s' "$spec" | cut -f2)
  image_name=$(printf '%s' "$spec" | cut -f3)
  images=$(cw_live_images "$ns" "$deploy" 2>/dev/null) || {
    CW_TARGET_CARRIED_REASON="deploy landing unreadable: the target's pod images could not be read"
    return 3
  }
  # Every pod must run one tag of the image: two tags is a rollout still in
  # progress, which proves nothing about the pods that have not moved yet.
  for img in ${images//,/ }; do
    ref=${img##*/}
    case "$ref" in *@*) continue ;; *:*) ;; *) continue ;; esac
    [ "${ref%%:*}" = "$image_name" ] || continue
    if [ -n "$tag" ] && [ "$tag" != "${ref#*:}" ]; then
      return 1
    fi
    tag=${ref#*:}
  done
  [ -n "$tag" ] || return 1
  number=${tag##*-}
  [ "$number" != "$tag" ] || return 1
  case "$number" in ''|*[!0-9]*) return 1 ;; esac
  cache="$(cw_watch_dir "$id")/builds"
  # One build answer must not spend the sample's whole budget: it is bounded by
  # the sample deadline and by one forge timeout, leaving the rest of the sample
  # for the target's other metrics.
  if [ -n "$CW_BUDGET_START" ]; then
    deadline=$(( CW_BUDGET_START + SAMPLE_DEADLINE_SECONDS ))
    cap=$(( $(cw_now) + FORGE_TIMEOUT ))
    if [ "$cap" -lt "$deadline" ]; then deadline=$cap; fi
  fi
  row=$(awk -F'\t' -v t="$tag" '$1 == t { print $2 "\t" $3; exit }' "$cache" 2>/dev/null || true)
  if [ -n "$row" ]; then
    sha=${row%%$'\t'*}
    state=${row#*$'\t'}
  else
    merge=$(cw_merge_sha "$id")
    # The forge not naming the merge sha yet is a wait, not a failed read: the
    # watch records it as awaiting the deploy, as the header documents.
    [ -n "$merge" ] || return 1
    cw_trace build "$ns/$deploy"
    if ! sha=$(cw_image_build_sha "$build_repo" "$workflow" "$number" "$repo" "$deadline"); then
      CW_TARGET_CARRIED_REASON="deploy landing unreadable: the build commit of image $tag could not be read from $build_repo $workflow"
      return 3
    fi
    state=$(cw_forge_carries_state "$owner/$repo" "$merge" "$sha" "$deadline")
    if [ "$state" = unreadable ]; then
      CW_TARGET_CARRIED_REASON="deploy landing unreadable: whether image $tag carries the merge could not be read from $owner/$repo"
      return 3
    fi
    [ ! -d "$(cw_watch_dir "$id")" ] \
      || printf '%s\t%s\t%s\n' "$tag" "$sha" "$state" >> "$cache" 2>/dev/null || true
  fi
  [ "$state" = carried ] || return 1
  CW_TARGET_CARRIED_EVIDENCE="$tag built from $(printf '%s' "$sha" | cut -c1-8)"
  return 0
}

cw_carried_path() { printf '%s/carried-at-register\n' "$(cw_watch_dir "$1")"; }

# A target still on the rollout it ran at registration is landed after all when
# that rollout was already built from the merge: the watch registered after the
# deploy, so there is no later rollout to wait for. The evidence is recorded once
# per target as "<ns>/<deploy><TAB><tag> built from <sha8>", because the
# baseline was then read from the released code (cw_take_sample, cw_carried_note).
cw_target_already_carried() {  # <watch-id> <ns> <deploy>
  local id=$1 target="$2/$3" file evidence rc
  while IFS=$'\t' read -r k v m; do
    [ "$k" = "$target" ] || continue
    CW_TARGET_CARRIED_EVIDENCE=$m
    CW_TARGET_CARRIED_REASON=$m
    return "$v"
  done <<CACHE
$CW_TARGET_CARRIED_CACHE
CACHE
  file=$(cw_carried_path "$id")
  if awk -F'\t' -v t="$target" '$1 == t { found = 1 } END { exit(found ? 0 : 1) }' "$file" 2>/dev/null; then
    CW_TARGET_CARRIED_EVIDENCE=''
    CW_TARGET_CARRIED_REASON=''
    CW_TARGET_CARRIED_CACHE="$CW_TARGET_CARRIED_CACHE$target	0	
"
    return 0
  fi
  cw_target_carries_merge "$id" "$2" "$3"; rc=$?
  evidence=$CW_TARGET_CARRIED_EVIDENCE
  if [ "$rc" -eq 0 ]; then
    [ ! -d "$(cw_watch_dir "$id")" ] \
      || printf '%s\t%s\n' "$target" "$evidence" >> "$file" 2>/dev/null || true
  elif [ "$rc" -ne 3 ]; then
    rc=1
  fi
  if [ "$rc" -eq 3 ]; then
    CW_TARGET_CARRIED_CACHE="$CW_TARGET_CARRIED_CACHE$target	3	$CW_TARGET_CARRIED_REASON
"
  else
    CW_TARGET_CARRIED_CACHE="$CW_TARGET_CARRIED_CACHE$target	$rc	$evidence
"
  fi
  return "$rc"
}

# One sentence naming every target the merge was already running on when the
# watch registered, or nothing. Pod logs and counters before that rollout are
# gone, so no pre-merge baseline is readable for them: restarts and 5xx are held
# to absolute bars (zero since the rollout) and p95 to its post-deploy reading.
cw_carried_note() {  # <watch-id>
  local file
  file=$(cw_carried_path "$1")
  [ -s "$file" ] || return 0
  printf 'the merge was already running at registration on %s, so no pre-merge baseline was readable: restarts and 5xx were held to absolute bars and p95 to its post-deploy reading\n' \
    "$(awk -F'\t' '{ printf "%s%s (%s)", (NR > 1 ? ", " : ""), $1, $2 }' "$file")"
}

# The landing gate: a Kubernetes target is scored only once the rollout it
# ran at registration have been replaced, or once that rollout is proven to be
# built from the merge already (cw_target_already_carried), so a sample can
# never report the code the release replaced as healthy and never waits for a
# deploy that already happened. 0 = landed or nothing to compare, 2 = still
# awaiting the rollout, 3 = the landing could not be read, with
# CW_TARGET_CARRIED_REASON naming the read that failed.
cw_target_landed() {  # <watch-id> <ns> <deploy> [<landed-file>]
  local id=$1 ns=$2 deploy=$3 landed=${4:-}
  local row recorded fingerprint current rc
  [ -n "$landed" ] || landed=$(cw_landed_path "$id")
  [ -f "$landed" ] || return 0
  row=$(awk -F'\t' -v t="$ns/$deploy" '$1 == t { print $2 "|" $3; found = 1 } END { exit(found ? 0 : 1) }' \
    "$landed" 2>/dev/null) || return 0
  recorded=${row%%|*}
  fingerprint=${row#*|}
  # No image was recorded for this target, so the rollout cannot be proven.
  # The watch still measures its metrics (a reader that works is worth more than
  # a silent 12h gap) but every verdict says the landing was never proven.
  [ -n "$recorded" ] || return 0
  if [ -n "$fingerprint" ]; then
    # A landing record from this release carries the fingerprint: the rollout is
    # proven by the template hash, so a change that leaves every image identical
    # (an env value, a routing table) still opens the gate.
    current=$(cw_live_fingerprint "$ns" "$deploy" 2>/dev/null) || {
      CW_TARGET_CARRIED_REASON="deploy landing unreadable: the target's pod fingerprint could not be read"
      return 3
    }
    if [ -z "$current" ]; then
      CW_TARGET_CARRIED_REASON="deploy landing unreadable: the target's pod fingerprint could not be read"
      return 3
    fi
    [ "$current" = "$fingerprint" ] || return 0
    rc=0
    cw_target_already_carried "$id" "$ns" "$deploy" || rc=$?
    [ "$rc" -eq 3 ] && return 3
    [ "$rc" -eq 0 ] && return 0
    return 2
  fi
  # A landed record written before the fingerprint existed compares the images,
  # which is all it recorded.
  current=$(cw_live_images "$ns" "$deploy" 2>/dev/null) || {
    CW_TARGET_CARRIED_REASON="deploy landing unreadable: the target's pod images could not be read"
    return 3
  }
  if [ -z "$current" ]; then
    CW_TARGET_CARRIED_REASON="deploy landing unreadable: the target's pod images could not be read"
    return 3
  fi
  [ "$current" = "$recorded" ] || return 0
  rc=0
  cw_target_already_carried "$id" "$ns" "$deploy" || rc=$?
  [ "$rc" -eq 3 ] && return 3
  [ "$rc" -eq 0 ] && return 0
  return 2
}

# Record the images and rollout fingerprint every Kubernetes target runs right
# now, the evidence the rollout must replace. Both come from one pod read, so a
# target can never be recorded with images but no fingerprint. A target whose
# pods cannot be read is recorded empty and its gate stays open (never scored).
cw_record_images() {  # <watch-id>
  local id=$1 ns deploy facts images hashes fingerprint out=''
  [ -z "${FM_CW_CLUSTER_DIR:-}" ] || return 0
  [ -f "$(cw_targets_path "$id")" ] || return 0
  while IFS=$'\t' read -r ns deploy; do
    [ -n "${ns:-}" ] || continue
    cw_within_budget || break
    facts=$(cw_pod_facts "$ns" "$deploy" 2>/dev/null || true)
    images=$(printf '%s' "$facts" | cut -f3)
    hashes=$(printf '%s' "$facts" | cut -f5)
    fingerprint=''
    [ -z "$images$hashes" ] || fingerprint="$images|$hashes"
    out="$out$ns/$deploy	$images	$fingerprint
"
  done < "$(cw_targets_path "$id")"
  printf '%s' "$out" | cw_write "$(cw_landed_path "$id")"
}

# cw_runs_awaiting_deploy <watch-id> <since-epoch> succeeds when a watch with no
# Deployment target has no completed deploy-workflow run for this release, and
# prints why. The Sentry gate uses it so a repository deployed by its own workflow
# (hydra) does not read its errors before that deploy has landed either.
cw_runs_awaiting_deploy() {  # <watch-id> <since-epoch>
  local id=$1 since=$2 run_repo workflow out rc seen=0 awaiting='' unreadable=''
  [ -f "$(cw_runs_path "$id")" ] || return 1
  while IFS=$'\t' read -r run_repo workflow; do
    [ -n "${run_repo:-}" ] || continue
    [ -n "${workflow:-}" ] || continue
    seen=1
    rc=0
    out=$(cw_live_deploy_run "$run_repo" "$workflow" "$since" "$(cw_merge_sha "$id")" 2>&1) || rc=$?
    [ "$rc" -eq 0 ] && continue
    case "$out" in
      # The run reader states its own wait, so the gate reuses that sentence
      # instead of wrapping a second "awaiting the deploy:" around it.
      awaiting\ the\ deploy:*) awaiting=$out ;;
      '') awaiting='awaiting the deploy: no run has been read' ;;
      *) unreadable=$out ;;
    esac
  done < "$(cw_runs_path "$id")"
  [ "$seen" -eq 1 ] || return 1
  # A read that failed for its own reason is unmeasured, never "awaiting".
  if [ -n "$unreadable" ]; then
    printf '%s\n' "$unreadable"
    return 0
  fi
  [ -n "$awaiting" ] || return 1
  printf '%s\n' "$awaiting"
  return 0
}

# cw_all_k8s_awaiting <watch-id>: 0 when every k8s target of the watch is still
# running the images it ran at registration, so no rollout has happened, 1 when
# at least one has landed, 3 when a landing could not be read, with
# CW_TARGET_CARRIED_REASON naming the read that failed.
cw_all_k8s_awaiting() {  # <watch-id>
  local id=$1 ns deploy landed seen=0 rc=1
  [ -f "$(cw_targets_path "$id")" ] || return 1
  while IFS=$'\t' read -r ns deploy; do
    [ -n "$ns" ] || continue
    seen=1
    landed=0
    cw_target_landed "$id" "$ns" "$deploy" || landed=$?
    [ "$landed" -eq 2 ] || {
      [ "$landed" -eq 3 ] && rc=3 || rc=1
      break
    }
    rc=0
  done < "$(cw_targets_path "$id")"
  [ "$seen" -eq 1 ] || return 1
  return "$rc"
}

# cw_unproven_landing <watch-id> prints the k8s targets whose pre-merge pod
# images were never readable, so no verdict can claim their rollout was seen.
cw_unproven_landing() {  # <watch-id>
  local id=$1 ns deploy recorded
  [ -f "$(cw_targets_path "$id")" ] || return 0
  while IFS=$'\t' read -r ns deploy; do
    recorded=$(awk -F'\t' -v t="$ns/$deploy" '$1 == t { print $2 }' "$(cw_landed_path "$id")" 2>/dev/null)
    [ -n "$recorded" ] || printf '%s/%s\n' "$ns" "$deploy"
  done < "$(cw_targets_path "$id")"
}

cw_mark_landed() {  # <watch-id> <ns> <deploy> <epoch>
  local id=$1 target="$2/$3"
  [ -f "$(cw_landed_at_path "$id")" ] || : > "$(cw_landed_at_path "$id")"
  grep -qF "$target" "$(cw_landed_at_path "$id")" 2>/dev/null && return 0
  printf '%s\t%s\n' "$target" "$4" >> "$(cw_landed_at_path "$id")" 2>/dev/null || true
}

cw_key_metric() { printf '%s\n' "${1%%@*}"; }
cw_key_target() { printf '%s\n' "${1#*@}"; }

cw_metric_relative() {
  case "$1" in http_5xx_per_min|restarts|p95_ms|sentry_new_issues) return 0 ;; *) return 1 ;; esac
}

# Resolve every target's pool inside the shared budget; an unresolved target has
# no pools line and its pool metric stays unmeasured.
cw_resolve_pools() {  # <watch-id>
  local id=$1 ns deploy spec out=''
  [ -f "$(cw_targets_path "$id")" ] || return 0
  while IFS=$'\t' read -r ns deploy; do
    [ -n "${ns:-}" ] || continue
    cw_within_budget || break
    spec=$(cw_resolve_pool_spec "$ns" "$deploy" 2>/dev/null) || continue
    [ -n "$spec" ] || continue
    out="$out$ns/$deploy	$spec
"
  done < "$(cw_targets_path "$id")"
  printf '%s' "$out" | cw_write "$(cw_pools_path "$id")"
}

# True when a metric's read needs the cluster, mirroring cw_sample_blocker: the
# Sentry and deploy-run reads go over the network, so neither is gated on the
# cluster probe.
cw_baseline_needs_cluster() {  # <metric>
  case "$1" in
    sentry_new_issues|deploy_run) return 1 ;;
  esac
  return 0
}

cw_capture_baseline() {  # <watch-id> <baseline-epoch>
  local id=$1 since=$2 key metric target value out cluster err rc
  out=''
  cw_budget_start
  cw_reasons_begin "$id"
  err=$(mktemp "${TMPDIR:-/tmp}/fm-cw-base.XXXXXX" 2>/dev/null) || err=/dev/null
  cluster=$(cw_cluster_probe || true)
  cw_resolve_pools "$id"
  [ -z "$cluster" ] || cw_record_reason "$id" "baseline" "cluster read failed: $cluster"
  [ -n "$cluster" ] || cw_prime_selectors "$id"
  [ -n "$cluster" ] || cw_prime_pod_facts "$id"
  cw_prime_merge_sha "$id"
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    metric=$(cw_key_metric "$key")
    target=$(cw_key_target "$key")
    value=''
    # Only a cluster-backed metric is gated on the probe. A Sentry or deploy-run
    # baseline is read over the network, so a cluster that is down at register
    # time must not cost the whole watch its relative bar.
    if [ -n "$cluster" ] && cw_baseline_needs_cluster "$metric"; then
      :
    elif cw_baseline_needs_cluster "$metric" || cw_within_budget; then
      rc=0
      value=$(cw_metric_read "$id" "$metric" "$target" baseline "$since" 2>"$err") || rc=$?
      if [ "$rc" -ne 0 ] || ! printf '%s' "$value" | grep -qE '^-?[0-9]+([.][0-9]+)?$'; then
        # A reader that explains itself on stdout ("no run since the merge")
        # supplies the reason; one that fails silently is reported by its stderr
        # or its exit status, so a baseline gap is always stated.
        if [ -n "$value" ] && ! printf '%s' "$value" | grep -qE '^[0-9]'; then
          cw_record_reason "$id" "$key" "$(printf '%s' "$value" | tail -1 | cut -c1-200)"
        else
          cw_record_reason "$id" "$key" "$(tail -1 "$err" 2>/dev/null | cut -c1-200)"
        fi
        value=''
      fi
    fi
    out="$out$key	$value
"
  done < <(cw_metric_keys "$id")
  [ "$err" = /dev/null ] || rm -f -- "$err" 2>/dev/null || true
  printf '%s' "$out" | cw_write "$(cw_baseline_path "$id")"
  cw_pool_memo_clear
}

cw_baseline_value() {  # <watch-id> <key>
  local file
  file=$(cw_baseline_path "$1")
  [ -f "$file" ] || return 1
  awk -F'\t' -v k="$2" '$1 == k { print $2; found=1 } END { exit(found ? 0 : 1) }' "$file"
}

# State the bar for one metric and report whether the value crosses it.
cw_metric_regressed() {  # <metric> <value> <baseline> <previous>
  local metric=$1 value=$2 baseline=$3 previous=$4
  [ -n "$value" ] || return 1
  case "$metric" in
    http_5xx_per_min) awk -v v="$value" -v b="$baseline" 'BEGIN { exit !((v+0) > 1 && (v+0) > 3*(b+0)) }' ;;
    restarts) awk -v v="$value" -v b="$baseline" 'BEGIN { exit !((v+0) > (b+0) + 1) }' ;;
    oomkilled) awk -v v="$value" 'BEGIN { exit !((v+0) > 0) }' ;;
    p95_ms) awk -v v="$value" -v b="$baseline" 'BEGIN { exit !((v+0) > (b+0) + 100 && (v+0) > 3*(b+0)) }' ;;
    pgbouncer_cl_waiting) awk -v v="$value" -v p="$previous" 'BEGIN { exit !((v+0) > 0 && (p+0) > 0) }' ;;
    rss_ratio) awk -v v="$value" 'BEGIN { exit !((v+0) > 0.85) }' ;;
    sentry_new_issues)
      awk -v v="$value" -v b="$baseline" -v min="$SENTRY_MIN_NEW" \
        'BEGIN { exit !((v+0) >= min && (v+0) > (b+0)) }' ;;
    # A failed deploy is not a regression of the running service: the change
    # never reached it. cw_take_sample reports it as absent instead.
    deploy_run) return 1 ;;
    *) return 1 ;;
  esac
}

# A scored deploy_run below 1 means the deploy run carrying the merge failed, so
# the change is absent from production rather than regressed in it.
cw_metric_absent() {  # <metric> <value>
  [ "$1" = deploy_run ] && [ -n "$2" ] || return 1
  awk -v v="$2" 'BEGIN { exit !((v+0) < 1) }'
}

cw_beta_metric_regressed() {  # <metric> <value> <baseline>
  case "$1" in
    oomkilled) awk -v v="$2" -v b="$3" 'BEGIN { exit !((v+0) > (b+0)) }' ;;
    rss_ratio) awk -v v="$2" -v b="$3" 'BEGIN { exit !((v+0) > (b+0) + 0.05) }' ;;
    *) cw_metric_regressed "$1" "$2" "$3" '' ;;
  esac
}

cw_previous_id() { printf '%s' "$1" | tr '/@' '__'; }

cw_previous_value() {  # <watch-id> <key>
  local file
  file=$(cw_last_path "$1" "$(cw_previous_id "$2")")
  [ -f "$file" ] || return 1
  cat "$file"
}

cw_set_previous_value() {  # <watch-id> <key> <value>
  printf '%s\n' "$3" > "$(cw_last_path "$1" "$(cw_previous_id "$2")")" 2>/dev/null || true
}

# Take one sample. Prints "metric<TAB>target<TAB>value<TAB>baseline" for the
# first bar crossed, or nothing when every scored metric is inside its bar.
# Appends one record per metric to samples.log:
#   epoch<TAB>offset<TAB>key<TAB>value<TAB>baseline<TAB>regressed<TAB>scored<TAB>awaiting
# where scored is 0 for an unmeasured value or a relative bar with no baseline,
# and awaiting is 1 when the only reason the value is missing is that the
# rollout had not landed yet. Awaiting is not a measurement gap: there was
# nothing to measure, so it never counts against a proven verdict the way a
# failed read does.
cw_take_sample() {  # <watch-id> <offset-seconds> <sample-epoch> <baseline-epoch>
  local id=$1 offset=$2 epoch=$3 baseline_epoch=$4
  local key metric target value baseline previous regressed scored awaiting first absent reason cluster err rc
  first=''
  absent=''
  cw_budget_start
  cw_reasons_begin "$id"
  err=$(mktemp "${TMPDIR:-/tmp}/fm-cw-read.XXXXXX" 2>/dev/null) || err=/dev/null
  # Prove the cluster answers once. Without this an unreachable cluster spent the
  # whole budget on reads that each failed the same way, and every watch
  # completed unmeasured while its record still looked like a normal watch.
  cluster=$(cw_cluster_probe || true)
  # Selectors before pod facts: the pod reads want each target's selector, and a
  # memo written inside a command substitution is lost, so priming it after them
  # spends a second cluster read on the same Deployment.
  [ -n "$cluster" ] || cw_prime_selectors "$id"
  [ -n "$cluster" ] || cw_prime_pod_facts "$id"
  cw_prime_merge_sha "$id"
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    metric=$(cw_key_metric "$key")
    target=$(cw_key_target "$key")
    value=''
    reason=''
    CW_SAMPLE_BLOCKER_REASON=''
    cw_sample_blocker "$id" "$metric" "$target" "$cluster" || true
    reason=$CW_SAMPLE_BLOCKER_REASON
    baseline=$(cw_baseline_value "$id" "$key" 2>/dev/null || true)
    # A target the merge was already running on at registration had its baseline
    # read from the released code, so the counters that baseline would excuse are
    # held to zero since the rollout instead (cw_carried_note states it).
    case "$metric" in
      restarts|http_5xx_per_min)
        if awk -F'\t' -v t="$target" '$1 == t { found = 1 } END { exit(found ? 0 : 1) }' \
          "$(cw_carried_path "$id")" 2>/dev/null; then
          baseline=0
        fi
        ;;
    esac
    previous=$(cw_previous_value "$id" "$key" 2>/dev/null || true)
    scored=1
    if [ -z "$reason" ]; then
      rc=0
      value=$(cw_metric_read "$id" "$metric" "$target" sample "$baseline_epoch" 2>"$err") || rc=$?
      if [ "$rc" -ne 0 ] || [ -z "$value" ]; then
        # A reader that explains itself on stdout ("no run since the merge")
        # hands that sentence back as the reason; one that fails silently is
        # reported by its stderr or its exit status.
        if [ -n "$value" ] && ! printf '%s' "$value" | grep -qE '^-?[0-9]+([.][0-9]+)?$'; then
          reason=$value
        else
          reason=$(tail -1 "$err" 2>/dev/null | cut -c1-200)
          [ -n "$reason" ] || reason="read exited $rc with no value"
        fi
        value=''
      elif ! printf '%s' "$value" | grep -qE '^-?[0-9]+([.][0-9]+)?$'; then
        reason=$value
        value=''
      fi
    fi
    [ -n "$value" ] || cw_record_reason "$id" "$key" "${reason:-unmeasured}"
    [ -n "$value" ] || scored=0
    awaiting=0
    case "$reason" in 'awaiting the deploy:'*) awaiting=1 ;; esac
    if [ "$scored" -eq 1 ] && cw_metric_relative "$metric" && [ -z "$baseline" ]; then
      scored=0
      cw_record_reason "$id" "$key" "baseline could not be read, so the relative bar was not scored"
    fi
    regressed=0
    if [ "$scored" -eq 1 ] && cw_metric_regressed "$metric" "$value" "$baseline" "$previous"; then
      regressed=1
      [ -n "$first" ] || first="$metric	$target	$value	$baseline"
    fi
    if [ "$scored" -eq 1 ] && cw_metric_absent "$metric" "$value"; then
      [ -n "$absent" ] || absent="absent	$metric	$target	$value"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$epoch" "$offset" "$key" "$value" "$baseline" "$regressed" "$scored" "$awaiting" \
      >> "$(cw_samples_path "$id")"
    [ -z "$value" ] || cw_set_previous_value "$id" "$key" "$value"
  done < <(cw_metric_keys "$id")
  [ "$err" = /dev/null ] || rm -f -- "$err" 2>/dev/null || true
  cw_pool_memo_clear
  if [ -n "$absent" ]; then
    printf '%s\n' "$absent"
  elif [ -n "$first" ]; then
    printf '%s\n' "$first"
  fi
  return 0
}

# Why a metric cannot be read right now, as one stated reason, or nothing when
# the read may proceed. A Kubernetes target that has not seen its rollout is
# awaiting the deploy, and an unreachable cluster is named once instead of being
# retried per metric.
CW_SAMPLE_BLOCKER_REASON=''
cw_sample_blocker() {  # <watch-id> <metric> <target> <cluster-probe-error>
  local id=$1 metric=$2 target=$3 cluster=$4 ns deploy landed since out
  CW_SAMPLE_BLOCKER_REASON=''
  case "$metric" in
    sentry_new_issues)
      # Sentry errors are only the release's once its landing is proven: the
      # watched Deployments' rollout when the watch has any, otherwise its own
      # deploy workflow's run for this merge. A watch with neither has nothing
      # better to prove, so its Sentry read proceeds.
      #
      # Proving a rollout costs a pod read, and a spent sample budget buys none:
      # the pod-backed metrics state that budget themselves, and a landing the
      # sample could not read is unproven (as an unreadable fingerprint already
      # is), never a silent reason to skip a network read.
      if [ -s "$(cw_targets_path "$id")" ]; then
        if cw_within_budget; then
          landed=0
          cw_all_k8s_awaiting "$id" || landed=$?
          case "$landed" in
            0) CW_SAMPLE_BLOCKER_REASON='awaiting the deploy: no watched Deployment has rolled out yet' ;;
            3) if [ -n "$CW_TARGET_CARRIED_REASON" ]; then
                 CW_SAMPLE_BLOCKER_REASON=$CW_TARGET_CARRIED_REASON
               else
                 CW_SAMPLE_BLOCKER_REASON="deploy landing unreadable: the watched Deployments' rollout could not be read"
               fi ;;
          esac
        fi
        return 0
      fi
      since=$(cw_meta_get "$id" t0 || true)
      out=$(cw_runs_awaiting_deploy "$id" "$since" || true)
      CW_SAMPLE_BLOCKER_REASON=$out
      return 0
      ;;
    deploy_run) return 0 ;;
  esac
  if [ -n "$cluster" ]; then
    CW_SAMPLE_BLOCKER_REASON="cluster read failed: $cluster"
    return 0
  fi
  case "$target" in
    */*) ns=${target%%/*}; deploy=${target#*/} ;;
    *) return 0 ;;
  esac
  # A spent budget is stated as itself before the pod read this metric needs, and
  # stops that read only: the Sentry and deploy-workflow reads above go over the
  # network with their own bounds, so a budget cluster reads spent never costs
  # them the sample.
  cw_within_budget || { CW_SAMPLE_BLOCKER_REASON='sample budget spent before this metric was read'; return 0; }
  landed=0
  cw_target_landed "$id" "$ns" "$deploy" || landed=$?
  case "$landed" in
    2) CW_SAMPLE_BLOCKER_REASON='awaiting the deploy: the pods still run the image they ran at registration' ;;
    3) if [ -n "$CW_TARGET_CARRIED_REASON" ]; then
         CW_SAMPLE_BLOCKER_REASON=$CW_TARGET_CARRIED_REASON
       else
         CW_SAMPLE_BLOCKER_REASON="deploy landing unreadable: the target's pod fingerprint could not be read"
       fi ;;
  esac
  return 0
}

# --- verdict ------------------------------------------------------------------

cw_verdict_line() {  # <watch-id>
  local id=$1 file
  file=$(cw_verdict_path "$id")
  if [ -f "$file" ]; then
    cat "$file"
    return 0
  fi
  printf 'change-watch clean so far (%s)\n' "$(cw_progress_label "$id")"
}

cw_schedule_latest() {  # <watch-id>
  awk -F'\t' 'NR == 1 || $1 > max { max = $1 } END { if (max == "") max = 0; print max }' \
    "$(cw_schedule_path "$1")" 2>/dev/null || echo 0
}

cw_progress_label() {  # <watch-id>
  local id=$1 t0 now latest offset
  t0=$(cw_meta_get "$id" t0 || true)
  now=$(cw_now)
  latest=$(cw_schedule_latest "$id")
  [ -n "$t0" ] || { printf 'armed\n'; return 0; }
  offset=$(( now - t0 ))
  [ "$offset" -ge 0 ] || offset=0
  printf '+%dm of +%dm' "$((offset / 60))" "$((latest / 60))"
}

# --- durable row --------------------------------------------------------------
#
# One row per merge, at state/change-watch/rows/<watch-id>.json. It is written
# when the watch is registered (terminal_state "open") and rewritten at the
# terminal verdict, so a merge always has exactly one durable record of what
# was measured; `rederive` may rewrite that terminal state once more, and a watch
# registered before the row was written at registration gets one from it too.
# Every row `rederive` writes OR rewrites carries
# derived_epoch, so a reconstructed row is never mistaken for one a live drive
# wrote.
# state/change-watch/ is not a task record: bin/fm-teardown.sh removes
# state/<task>.* and never this tree, so the row outlives the task.
#
# Schema (one JSON object, one line):
#   version            "fm-change-watch-row-v1"
#   kind               "merge" for a merge watch, "claim" for a done claim
#                      (the "claim rows" section owns the claim row)
#   deploy             merge rows only: "expected" when the merge touched a
#                      deployable surface, "not-applicable" when it did not
#   watch_id           the watch directory name
#   task, pr_url       the owning task and the merged pull request; pr_url is
#                      null for a claim registered before any PR exists
#   merge_epoch        the rollout epoch the schedule is measured from, or null
#   registered_epoch   when the watch was registered, or null
#   deadline_epoch     claim rows only: when an open claim becomes overdue
#   completed_epoch    when the terminal state was first written, or null while
#                      open; preserved when rederive rewrites the row
#   derived_epoch      when rederive reconstructed the row, absent for a live row
#   rescore            present only on a row rescore rewrote: {"epoch", "key",
#                      "value", "baseline" (null when unmeasured),
#                      "comparison", "prior_state", "prior_reason"}, the
#                      deciding reading and the verdict it replaced
#   readings           one key per scheduled offset (SCHEDULE_OFFSETS for a
#                      merge, CLAIM_OFFSETS for a claim): <reading>|null
#   acceptance         null for a merge row; for a claim row {"probe_path",
#                      "sha256", "last_exit", "last_epoch"}
#   real_user_check    "observed" | "not-observed" | "not-applicable"
#   real_user_reason   why the real-user check reads as it does
#   unmeasured_metrics metric keys no sample ever scored
#   unproven_targets   targets whose rollout was never proven
#   terminal_state     "open" | "proven" | "regressed" | "absent" |
#                      "unmeasurable-with-reason" | "not-applicable"
#   reason             the human sentence behind the terminal state
#
# A reading is {"at": <epoch>, "scored": <n>, "unmeasured": <n>,
# "awaiting": <n>, "regressed": <n>, "measured": <bool>,
# "values": {"<metric>@<target>": "<value>", ...}}, or null when no sample was
# ever taken at that offset. "measured" is true only when the reading scored
# something: a reading made entirely of samples that awaited their rollout is not
# a measurement, and neither is one that failed to read. Both are present but
# measured nothing, which is exactly what makes a row unproven.

cw_rows_dir() { printf '%s/rows\n' "$WATCH_ROOT"; }
cw_row_path() { printf '%s/%s.json\n' "$(cw_rows_dir)" "$1"; }

# The terminal state a watch's durable row records, or nothing when the watch
# never wrote a row. The row, not the verdict file, is the authority the gates
# read: deleting a verdict can remove the wake's detail but never the record that
# a merge ended without a measurement or regressed. A watch that never wrote one
# is derived from the readings it still holds by cw_rowless_state, below.
cw_row_state() {  # <watch-id>
  local row
  row=$(cw_row_path "$1")
  [ -f "$row" ] || return 0
  sed -n 's/.*"terminal_state": "\([^"]*\)".*/\1/p' "$row" 2>/dev/null | tail -1
}

# The pull request a durable row belongs to, so a re-derivation rewrites the row
# it read rather than one with the merge facts dropped.
cw_row_url() {  # <watch-id>
  local row
  row=$(cw_row_path "$1")
  [ -f "$row" ] || return 0
  sed -n 's/.*"pr_url": "\([^"]*\)".*/\1/p' "$row" 2>/dev/null | tail -1
}

# The reason a watch's durable row recorded, for the refusal text.
cw_row_reason() {  # <watch-id>
  local row
  row=$(cw_row_path "$1")
  [ -f "$row" ] || return 0
  sed -n 's/.*"reason": "\(.*\)".*/\1/p' "$row" 2>/dev/null | tail -1
}

# The task a durable row belongs to, so a merge whose gap never created a watch
# directory is still found by the task's gate.
cw_row_task() {  # <watch-id>
  local row
  row=$(cw_row_path "$1")
  [ -f "$row" ] || return 0
  sed -n 's/.*"task": "\([^"]*\)".*/\1/p' "$row" 2>/dev/null | tail -1
}

cw_json_escape() {  # <text>
  printf '%s' "$1" | awk '
    BEGIN { ORS = "" }
    {
      if (NR > 1) print "\\n"
      line = $0
      gsub(/\\/, "\\\\", line)
      gsub(/"/, "\\\"", line)
      gsub(/\t/, "\\t", line)
      gsub(/\r/, "\\r", line)
      gsub(/[\001-\010\013\014\016-\037]/, "", line)
      print line
    }'
}

cw_json_string() { printf '"%s"' "$(cw_json_escape "$1")"; }

# A string, or JSON null when it is empty: a claim registered before any PR
# exists has no pr_url yet, and null says so where "" would read as a URL.
cw_json_or_null() {  # <text>
  if [ -n "$1" ]; then cw_json_string "$1"; else printf 'null'; fi
}

# One reading of the row: the samples this watch took at one schedule offset.
cw_reading_json() {  # <watch-id> <offset-seconds>
  local id=$1 offset=$2 samples
  samples=$(cw_samples_path "$id")
  [ -f "$samples" ] || { printf 'null'; return 0; }
  awk -F'\t' -v offset="$offset" '
    function esc(s) {
      gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s)
      gsub(/\t/, "\\t", s); gsub(/\r/, "\\r", s)
      return s
    }
    $2 == offset {
      if (at == "") at = $1
      if ($7 == 1) { scored++; values = values (n++ ? ", " : "") "\"" esc($3) "\": \"" esc($4) "\"" }
      else if ($8 == 1) awaiting++
      else unmeasured++
      if ($6 == 1) regressed++
    }
    END {
      if (at == "") { printf "null"; exit }
      # A reading is measured only when it scored something. A sample that was
      # only waiting for its rollout to land read nothing, so a reading made
      # entirely of those is not a measurement: counting it as one reports a
      # watch whose whole window elapsed during a rollout as clean, and a
      # verdict that cannot tell "we looked and it was fine" from "we never
      # looked" is the false clean this bar exists to prevent. A reading whose
      # samples all failed to read is a gap for the same reason.
      measured = (scored > 0) ? "true" : "false"
      printf "{\"at\": %s, \"scored\": %d, \"unmeasured\": %d, \"awaiting\": %d, \"regressed\": %d, \"measured\": %s, \"values\": {%s}}", at, scored, unmeasured, awaiting, regressed, measured, values
    }
  ' "$samples"
}

# The real-user check: http_5xx_per_min is read from the pods' own access logs,
# so a scored reading of it is the only evidence in this watch that a real user
# request was observed. A watch with no such key has no real-user surface. It is
# recorded, never a gate on proven: a service whose access logs are not readable
# is already named by the metric gap, and gating on it would make every such
# watch permanently unmeasurable.
cw_real_user_check() {  # <watch-id> -> "<state>\t<reason>"
  local id=$1 samples
  if [ -z "$(cw_metric_keys "$id" | awk -F@ '$1 == "http_5xx_per_min" { print; exit }')" ]; then
    printf 'not-applicable\tno http_5xx_per_min target: this watch has no real-user surface\n'
    return 0
  fi
  samples=$(cw_samples_path "$id")
  if [ -f "$samples" ] \
    && awk -F'\t' '$3 ~ /^http_5xx_per_min@/ && $7 == 1 { found = 1 } END { exit !found }' "$samples"; then
    printf 'observed\treal user traffic was read from the pods\047 own access logs\n'
  else
    printf 'not-observed\thttp_5xx_per_min was never scored, so no real user request was observed\n'
  fi
}

# Write the one durable row for this merge. <task>/<url>/<merge-epoch>/
# <registered-epoch> are only used when the watch has no metadata of its own,
# which is the not-applicable case: a merge that touched no deployable surface
# still gets its row, because "every merge writes one durable row" is the
# contract and a row saying why nothing was measurable is the honest record.
cw_row_write() {  # <watch-id> <terminal-state> <reason> [<task>] [<url>] [<merge-epoch>] [<registered-epoch>] [<completed-epoch>] [<derived-epoch>] [<deploy-expected>] [<rescore-json>]
  local id=$1 state=$2 reason=$3 task=${4:-} url=${5:-} t0=${6:-} created=${7:-} completed_at=${8:-} derived=${9:-} deploy=${10:-} rescore=${11:-}
  local completed readings offset ru ru_reason gaps unproven beta carried
  if cw_watch_exists "$id"; then
    task=$(cw_meta_get "$id" task || true)
    url=$(cw_meta_get "$id" pr_url || true)
    t0=$(cw_meta_get "$id" t0 || true)
    created=$(cw_meta_get "$id" created || true)
    [ -n "$deploy" ] || deploy=$(cw_meta_get "$id" deploy_expected || true)
  fi
  case "$deploy" in
    no|not-applicable) deploy=not-applicable ;;
    *) deploy=expected ;;
  esac
  # The beta verdict belongs in the durable row, so a merge whose beta stage
  # measured nothing (or measured a regression) is recalled from the row itself
  # rather than from a printed line. Doing it here means an open row and its
  # terminal rewrite carry the same beta fact; the caller adds it explicitly only
  # when the merge created no watch directory to hold a beta record.
  beta=$(cw_beta_verdict "$id")
  if [ -n "$beta" ]; then
    case "$reason" in
      *"$beta"*) ;;
      *) reason="$reason; beta: $beta" ;;
    esac
  fi
  # A watch that registered after its deploy says how its baseline was taken, so
  # the row never reads as a relative verdict it could not have reached.
  carried=$(cw_carried_note "$id")
  if [ -n "$carried" ]; then
    case "$reason" in
      *"$carried"*) ;;
      *) reason="$reason; $carried" ;;
    esac
  fi
  # A re-derivation rewrites a verdict that was already reached, so it keeps the
  # completion epoch it found: the 7-day acceptance is measured from when the
  # merge completed, and re-reading the readings never moves that clock.
  case "$state" in
    open) completed=null ;;
    *) completed=${completed_at:-$(cw_now)} ;;
  esac
  # Every scheduled offset is recorded, so the reading that decided a terminal
  # state is always in the row, whichever offset it was taken at.
  readings=''
  for offset in $SCHEDULE_OFFSETS; do
    readings="$readings${readings:+, }\"$offset\": $(cw_reading_json "$id" "$offset")"
  done
  ru=$(cw_real_user_check "$id")
  ru_reason=${ru#*$'\t'}
  ru=${ru%%$'\t'*}
  gaps=$(cw_measured_gaps "$id")
  unproven=$(cw_unproven_landing "$id" | paste -sd ',' - | sed 's/,/, /g')
  mkdir -p "$(cw_rows_dir)" 2>/dev/null || true
  chmod 0700 "$(cw_rows_dir)" 2>/dev/null || true
  {
    printf '{"version": "fm-change-watch-row-v1"'
    printf ', "kind": "merge"'
    printf ', "deploy": %s' "$(cw_json_string "$deploy")"
    printf ', "watch_id": %s' "$(cw_json_string "$id")"
    printf ', "task": %s' "$(cw_json_string "$task")"
    printf ', "pr_url": %s' "$(cw_json_or_null "$url")"
    printf ', "merge_epoch": %s' "${t0:-null}"
    printf ', "registered_epoch": %s' "${created:-null}"
    printf ', "completed_epoch": %s' "$completed"
    printf ', "readings": {%s}' "$readings"
    printf ', "acceptance": null'
    printf ', "real_user_check": %s' "$(cw_json_string "$ru")"
    printf ', "real_user_reason": %s' "$(cw_json_string "$ru_reason")"
    printf ', "unmeasured_metrics": %s' "$(cw_json_string "$gaps")"
    printf ', "unproven_targets": %s' "$(cw_json_string "$unproven")"
    printf ', "terminal_state": %s' "$(cw_json_string "$state")"
    # Provenance, not a waiver: a row reconstructed from readings a watch already
    # held says so, with the epoch it was reconstructed at, so a later reader can
    # tell a live row from a derived one without consulting anything else.
    [ -n "$derived" ] && printf ', "derived_epoch": %s' "$derived"
    # The reading a rescore decided from travels with the verdict it produced.
    [ -n "$rescore" ] && printf ', "rescore": %s' "$rescore"
    printf ', "reason": %s}\n' "$(cw_json_string "$reason")"
  } | cw_write "$(cw_row_path "$id")" \
    || notice "change-watch: could not write the durable row for $id"
}

# Targets that never scored a reading and are not a Sentry project or a deploy
# workflow run: the Kubernetes Deployments, whose own signals are the release.
cw_unread_deployments() {  # <watch-id>
  cw_unmeasured_targets "$1" | grep -v -e '^sentry/' -e '^run/' || true
}

# The terminal state of a finished watch, as "<state>\t<reason>".
#
# The verdict rests on the +6h reading, the last of the three the row records,
# plus the Deployments themselves: proven needs that reading to have measured
# something, at least one target of any kind to have been recorded, and every
# Deployment target measured at least once.
# The recorded-target clause is what keeps the Deployment bar from holding
# vacuously: with nothing on record there was nothing to apply it to, so the
# readings alone cannot prove the merge. Anything less is
# unmeasurable-with-reason naming what is missing. A missing +6h reading is never
# a pass.
#
# An EARLIER reading that measured nothing is not terminal. The +15m read can fail
# for a reason that has nothing to do with the change - a log format that lands
# with the deploy, a series that arrives with the rollout - and the +1h and +6h
# readings then measure the release directly. Latching such a watch to
# unmeasurable made 66 merged pull requests look unverified while their own rows
# held the measurements, so the earlier failure is disclosed in the reason and
# superseded by the later evidence.
#
# Two kinds of shortfall are never collapsed into one another: a Deployment that
# never scored is a read that failed, because the release itself was never
# measured and the row stays unmeasurable; a metric key or a sentry/ and run/
# target that never scored is a coverage gap, named in the reason and in the
# row's unmeasured_metrics but never a verdict on its own, because what it leaves
# unread is a slice of a surface that was otherwise measured.
#
# A reading that only ever waited for its rollout to land is not a measurement:
# the deploy had not happened yet, so nothing was read. A watch whose whole
# window elapsed that way ends unmeasurable and names the case, because a verdict
# that cannot tell "we looked and it was fine" from "we never looked" is the
# false clean this bar exists to prevent. A watch whose rollout never landed at
# all ends unmeasurable for the same reason, and cw_unread_deployments names the
# Deployments that never scored.
#
# <note> explains a schedule that was cut short (an interrupted drive). It is
# carried into the reason so a proof taken by a stopped drive says so.
cw_terminal_state() {  # <watch-id> [<note>] [<ignore-regression-flags>]
  local id=$1 note=${2:-} ignore_flags=${3:-} r json final='' empty='' prior_empty='' empties=0 missing=''
  local unread gaps why='' superseded='' plural='s' recorded=0 seen=''
  local all_awaiting=''
  # A regression a reading actually recorded is proof of a bad change, and it
  # outranks every later consideration: a watch that saw one is never clean, and
  # reporting it as a measurement gap would state the opposite of what the
  # readings found. The flag is the samples' regressed column, so a directory
  # whose drive detected a regression but wrote no row still carries the verdict
  # it earned instead of losing it to the row it never got. A rescore, which has
  # already re-scored those flags under the current rule, asks for them ignored.
  [ -n "$ignore_flags" ] || seen=$(awk -F'\t' '
    $6 == 1 {
      printf "regressed at +%dm on %s", $2 / 60, $3
      if ($4 != "") printf " (%s", $4
      if ($5 != "") printf "%sbaseline %s", ($4 != "" ? " vs " : " ("), $5
      if ($4 != "" || $5 != "") printf ")"
      print ""
      exit
    }' "$(cw_samples_path "$id")" 2>/dev/null)
  if [ -n "$seen" ]; then
    printf 'regressed\t%s\n' "$seen"
    return 0
  fi
  for r in 900 3600 21600; do
    json=$(cw_reading_json "$id" "$r")
    if [ "$json" = null ]; then
      missing="$missing${missing:+, }+$((r / 60))m"
    elif printf '%s' "$json" | grep -q '"measured": true'; then
      :
    else
      empty="$empty${empty:+, }+$((r / 60))m"
      empties=$((empties + 1))
      [ "$r" -eq 21600 ] || prior_empty="$prior_empty${prior_empty:+, }+$((r / 60))m"
    fi
    [ "$r" -ne 21600 ] || final=$json
  done
  # A +6h reading made entirely of samples that were still waiting for their
  # rollout read nothing at all, so it is not a measurement and the watch owes a
  # re-registration. Naming the case keeps it apart from a read that failed.
  if [ "$final" != null ] \
    && printf '%s' "$final" | grep -q '"scored": 0,' \
    && printf '%s' "$final" | grep -q '"unmeasured": 0,' \
    && ! printf '%s' "$final" | grep -q '"awaiting": 0,'; then
    all_awaiting=1
  fi
  unread=$(cw_unread_deployments "$id" | paste -sd ',' - | sed 's/,/, /g')
  # "Every Deployment target was measured" is vacuously true for a watch that
  # recorded no target of any kind, which would let readings alone stand as proof
  # of a merge nothing was watched for. The bar was never applied there, so that is
  # a measurement gap and not a clean verdict. A Sentry-only or deploy-workflow
  # watch is a different case and does complete clean: it records targets, they are
  # simply not Deployments, and its note names only what it measured.
  recorded=$(cw_target_ids "$id" | grep -c .)
  gaps=$(cw_measured_gaps "$id")
  [ "$empties" -ne 1 ] || plural=''
  [ "$empties" -eq 0 ] \
    || superseded="the $empty reading${plural} measured nothing, superseded by later readings"
  if [ "$final" != null ] \
    && printf '%s' "$final" | grep -q '"measured": true' \
    && [ "${recorded:-0}" -gt 0 ] \
    && [ -z "$unread" ]; then
    printf 'proven\t%s\n' \
      "${note:+$note; }the +6h reading measured and every Deployment target was measured at least once""${superseded:+; $superseded}${gaps:+; never measured: $gaps}"
    return 0
  fi
  if [ -n "$all_awaiting" ]; then
    why='the +6h reading awaited a rollout'
    [ -z "$prior_empty" ] || why="$why; nothing measured at $prior_empty"
  else
    [ -z "$empty" ] || why="nothing measured at $empty"
  fi
  [ -z "$missing" ] || why="$why${why:+; }no reading at $missing"
  [ -z "$unread" ] || why="$why${why:+; }never measured: $unread"
  [ -n "$why" ] || why='the watch registered no metric'
  printf 'unmeasurable-with-reason\t%s%s\n' "${note:+$note; }" "$why"
}

cw_record_regression() {  # <watch-id> <offset-seconds> <metric> <target> <value> <baseline>
  local id=$1 offset=$2 metric=$3 target=$4 value=$5 baseline=$6 tick line
  tick=$((offset / 60))
  line=$(printf 'regressed at +%dm on %s (%s vs baseline %s)' \
    "$tick" "$metric" "${value:-unmeasured}" "${baseline:-unmeasured}")
  printf '%s\n' "$line" | cw_write "$(cw_verdict_path "$id")"
  {
    printf 'metric=%s\n' "$metric"
    printf 'target=%s\n' "$target"
    printf 'value=%s\n' "$value"
    printf 'baseline=%s\n' "$baseline"
    printf 'offset=%s\n' "$offset"
    printf 'tick=%s\n' "$tick"
  } | cw_write "$(cw_watch_dir "$id")/regression"
  cw_row_write "$id" regressed "$line"
  printf '%s\n' "$line"
}

# The deploy run carrying the merge failed, so the change never reached
# production. When the merge touched something deployable that is absent: a
# terminal failure distinct from a regression, with its own wake and steer. A
# watch that expects no deploy keeps no deploy-run target, so it never reaches
# this path; its row records the deploy as not-applicable instead.
cw_record_absent() {  # <watch-id> <offset-seconds> <metric> <target> <value>
  local id=$1 offset=$2 metric=$3 target=$4 value=$5 tick line task url rc send_cmd
  tick=$((offset / 60))
  task=$(cw_meta_get "$id" task || true)
  url=$(cw_meta_get "$id" pr_url || true)
  line="absent at +${tick}m: the deploy run carrying the merge failed on $target ($metric $value), so the change is not in production"
  printf '%s\n' "$line" | cw_write "$(cw_verdict_path "$id")"
  cw_row_write "$id" absent "$line"
  printf '%s\n' "$line"
  cw_mark_once "$(cw_watch_dir "$id")/absent-reported" || return 0
  fm_wake_append check "change-watch-$id-absent" \
    "check: change-watch $task $url absent (deploy run failed at +${tick}m on $target)" 2>/dev/null \
    || notice "change-watch: could not queue the absent wake for $url"
  [ -n "$task" ] || return 0
  send_cmd=${FM_CW_SEND_CMD:-$SCRIPT_DIR/fm-send.sh}
  if [ -x "$send_cmd" ] || command -v "$send_cmd" >/dev/null 2>&1; then
    rc=0
    FM_HOME="$FM_HOME" "$send_cmd" "$task" \
      "change-watch $url is absent from production: the deploy run carrying the merge failed at +${tick}m on $target; get it deployed before claiming it landed" \
      >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 0 ] || notice "change-watch: could not steer $task (rc=$rc); the wake carries the reason"
  fi
}

# Create a marker exactly once; exit 0 only for the creating call.
cw_mark_once() {  # <path>
  local path=$1
  (umask 077; set -C; : > "$path") 2>/dev/null
}

cw_regression_field() {  # <watch-id> <key>
  grep "^$2=" "$(cw_watch_dir "$1")/regression" 2>/dev/null | cut -d= -f2- || true
}

cw_report_regression() {  # <watch-id>
  local id=$1 task url metric target value baseline tick line rc send_cmd
  cw_watch_exists "$id" || return 0
  [ -f "$(cw_watch_dir "$id")/regression" ] || return 0
  cw_mark_once "$(cw_watch_dir "$id")/reported" || return 0
  task=$(cw_meta_get "$id" task || true)
  url=$(cw_meta_get "$id" pr_url || true)
  metric=$(cw_regression_field "$id" metric)
  target=$(cw_regression_field "$id" target)
  value=$(cw_regression_field "$id" value)
  baseline=$(cw_regression_field "$id" baseline)
  tick=$(cw_regression_field "$id" tick)
  [ -n "$metric" ] || return 0

  line="check: change-watch $task $url $metric regressed"
  fm_wake_append check "change-watch-$id" "$line" 2>/dev/null \
    || notice "change-watch: could not queue the regression wake for $url"

  if [ -n "$task" ]; then
    send_cmd=${FM_CW_SEND_CMD:-$SCRIPT_DIR/fm-send.sh}
    if [ -x "$send_cmd" ] || command -v "$send_cmd" >/dev/null 2>&1; then
      rc=0
      FM_HOME="$FM_HOME" "$send_cmd" "$task" \
        "change-watch $url regressed at +${tick}m on $metric (target $target, measured ${value:-unmeasured}, baseline ${baseline:-unmeasured}); investigate before the next sample" \
        >/dev/null 2>&1 || rc=$?
      [ "$rc" -eq 0 ] || notice "change-watch: could not steer $task (rc=$rc); the wake carries the numbers"
    fi
  fi
}

cw_wiki_note() {  # <watch-id> <task> <url>
  local id=$1 task=$2 url=$3 cmd kinds targets body
  if [ "${FM_CW_NO_WIKI:-0}" = 1 ]; then
    notice "change-watch: wiki note skipped by FM_CW_NO_WIKI for $url"
    return 0
  fi
  cmd=wiki-retro
  if ! command -v "$cmd" >/dev/null 2>&1; then
    notice "change-watch: wiki note skipped (no $cmd on PATH) for $url"
    return 0
  fi
  # The body names the metric kinds and targets this watch actually measured: a
  # watch of a deploy workflow or a Sentry project alone must never claim a
  # Kubernetes metric it never read.
  kinds=$(cw_metric_keys "$id" | awk -F@ '{ print $1 }' | sort -u | paste -sd ',' - | sed 's/,/, /g')
  targets=$(cw_target_ids "$id" | sort -u | paste -sd ',' - | sed 's/,/, /g')
  body="Post-merge change watch for $url (task $task) completed clean at +12h: no regression on ${kinds:-any metric} against the pre-deploy baseline${targets:+ (watched: $targets)}."
  printf '%s\n' "$body" | "$cmd" "change-watch-clean-$id" "Post-merge change watch clean: $url" \
    >/dev/null 2>&1 || notice "change-watch: wiki note failed for $url"
}

cw_task_note() {  # <task> <url> <line>
  local task=$1 url=$2 line=$3
  if [ -n "$task" ] && [ -d "$STATE" ] \
    && { [ -f "$STATE/$task.meta" ] || [ -f "$STATE/$task.status" ]; }; then
    printf '%s\n' "$line" >> "$STATE/$task.status" 2>/dev/null \
      || notice "change-watch: could not append the completion note for $url"
  else
    notice "change-watch: completion note skipped for $url (task $task has no status record)"
  fi
}

cw_record_clean() {  # <watch-id> [<reason>]
  local id=$1 reason=${2:-} task url gaps unproven carried
  task=$(cw_meta_get "$id" task || true)
  url=$(cw_meta_get "$id" pr_url || true)
  [ -n "$reason" ] || reason='the +6h reading measured and every Deployment target was measured at least once'
  printf 'clean\n' | cw_write "$(cw_verdict_path "$id")"
  cw_row_write "$id" proven "$reason"
  cw_mark_once "$(cw_watch_dir "$id")/noted" || return 0
  gaps=$(cw_measured_gaps "$id")
  unproven=$(cw_unproven_landing "$id" | paste -sd ',' - | sed 's/,/, /g')
  carried=$(cw_carried_note "$id")
  if [ -n "$gaps" ] || [ -n "$unproven" ]; then
    cw_task_note "$task" "$url" \
      "note: change-watch clean for $url on every metric it could read${gaps:+; never measured: $gaps}${unproven:+; the rollout was never proven for: $unproven}${carried:+; $carried}"
    notice "change-watch: clean for $url on every metric it could read${gaps:+, but these metrics were never measured: $gaps}${unproven:+; the rollout could not be proven for: $unproven}"
    return 0
  fi
  cw_task_note "$task" "$url" "note: change-watch clean for $url${carried:+; $carried}"
  cw_wiki_note "$id" "$task" "$url"
}

# Queue the one check wake an unmeasurable merge produces. It carries the
# task, the PR and the reason so the gap is actionable without opening the row.
cw_queue_unmeasured_wake() {  # <watch-id> <task> <url> <reason>
  local id=$1 task=$2 url=$3 reason=$4 line
  line="check: change-watch $task $url unmeasurable ($reason)"
  fm_wake_append check "change-watch-$id-unmeasured" "$line" 2>/dev/null \
    || notice "change-watch: could not queue the unmeasurable wake for $url"
}

# A schedule that ended without the evidence a clean verdict needs is a
# FAILURE, not a quiet completion. It writes the unmeasurable-with-reason
# verdict and row, queues one check wake so the gap is actionable, and writes NO
# status note at all: the literal "change-watch completed unmeasured" line must
# never appear in a status log again, which is what the 7-day acceptance counts.
cw_record_unmeasured() {  # <watch-id> <reason>
  local id=$1 reason=$2 task url why
  task=$(cw_meta_get "$id" task || true)
  url=$(cw_meta_get "$id" pr_url || true)
  [ -n "$reason" ] || reason='the schedule ended without a scored reading for every target'
  # The reason the last sample recorded is what turns "unmeasured" into an
  # actionable gap instead of a mystery.
  why=$(awk -F'\t' '{ if ($2 != "") { print $2; exit } }' "$(cw_reasons_path "$id")" 2>/dev/null || true)
  [ -z "$why" ] || reason="$reason; last read reason: $why"
  printf 'unmeasurable-with-reason: %s\n' "$reason" | cw_write "$(cw_verdict_path "$id")"
  cw_row_write "$id" unmeasurable-with-reason "$reason"
  cw_mark_once "$(cw_watch_dir "$id")/noted" || return 0
  cw_queue_unmeasured_wake "$id" "$task" "$url" "$reason"
  notice "change-watch: unmeasurable for $url: $reason"
}

# Targets that never had one scored reading across the whole schedule.
cw_unmeasured_targets() {  # <watch-id>
  local id=$1 samples want
  samples=$(cw_samples_path "$id")
  [ -f "$samples" ] || : > "$samples"
  want=$(mktemp "${TMPDIR:-/tmp}/fm-cw-want.XXXXXX" 2>/dev/null) || { printf 'no temp file\n'; return 0; }
  cw_target_ids "$id" | sort -u > "$want"
  # With no target on record the want file is empty, and awk answers NR == FNR for
  # the first record of the second file too when the first file holds no lines, so
  # every sample would be read as a target and its epoch named as unmeasured. No
  # target means no unmeasured target.
  if [ ! -s "$want" ]; then
    rm -f -- "$want" 2>/dev/null || true
    return 0
  fi
  awk -F'\t' '
    NR == FNR { want[$1] = 1; next }
    $7 == 1 { key = $3; sub(/^[^@]*@/, "", key); delete want[key] }
    END { for (t in want) print t }
  ' "$want" "$samples" | sort
  rm -f -- "$want" 2>/dev/null || true
}

# Every metric key no sample of this watch ever scored, across every target it
# was registered with: the honest statement of what a clean verdict did and did
# not cover, so a release watched only for restarts and memory says exactly that
# and a target whose own pool or pods were never read is named as the gap it is.
cw_measured_gaps() {  # <watch-id>
  local id=$1 samples keys
  samples=$(cw_samples_path "$id")
  keys=$(cw_metric_keys "$id" | sort -u)
  [ -n "$keys" ] || return 0
  [ -f "$samples" ] || samples=/dev/null
  printf '%s\n' "$keys" | awk -F'\t' -v samples="$samples" '
    BEGIN {
      while ((getline line < samples) > 0) {
        n = split(line, f, "\t")
        if (n >= 7 && f[7] == 1) measured[f[3]] = 1
      }
      close(samples)
    }
    !($1 in measured) { printf "%s%s", sep, $1; sep = ", " }
  '
}

# The schedule ended: proven only when the +6h reading measured and every
# Deployment target was measured at least once; anything less is
# unmeasurable-with-reason.
cw_record_completion() {  # <watch-id>
  local id=$1 state reason
  state=$(cw_terminal_state "$id")
  reason=${state#*$'\t'}
  state=${state%%$'\t'*}
  case "$state" in
    proven) cw_record_clean "$id" "$reason" ;;
    regressed)
      # Recorded as the bad change it is; the reason already names the reading
      # that caught it, so nothing here re-derives what the drive found.
      printf 'regressed\n' | cw_write "$(cw_verdict_path "$id")"
      cw_row_write "$id" regressed "$reason" ;;
    *) cw_record_unmeasured "$id" "$reason" ;;
  esac
}

# A drive that stopped before the end of its schedule is judged by the readings
# it took: when those already proved the change it records a clean verdict, and
# otherwise the reason names the point it reached and one check wake carries it.
cw_record_interrupted() {  # <watch-id> <epoch>
  local id=$1 at=$2 t0 latest offset tick task url line state reason note
  cw_watch_done "$id" && return 0
  t0=$(cw_meta_get "$id" t0 || true)
  latest=$(cw_schedule_latest "$id")
  offset=$(( at - ${t0:-$at} ))
  [ "$offset" -ge 0 ] || offset=0
  [ "$offset" -le "$latest" ] || offset=$latest
  tick=$((offset / 60))
  note="interrupted at +${tick}m"
  # A stopped drive is judged by the readings it took, not by the fact that it
  # stopped. When those readings proved the change, the change is proven and the
  # interruption is stated in the reason; a refusal to accept that would have
  # made stopping the watch itself a way to lose a proof the watch already had.
  state=$(cw_terminal_state "$id" "$note")
  reason=$(printf '%s' "$state" | cut -f2-)
  state=$(printf '%s' "$state" | cut -f1)
  if [ "$state" = proven ]; then
    printf 'clean\n' | cw_write "$(cw_verdict_path "$id")"
    cw_row_write "$id" proven "$reason"
  elif [ "$state" = regressed ]; then
    printf 'regressed\n' | cw_write "$(cw_verdict_path "$id")"
    cw_row_write "$id" regressed "$reason"
  else
    printf '%s\n' "$note" | cw_write "$(cw_verdict_path "$id")"
    cw_row_write "$id" unmeasurable-with-reason "$reason"
  fi
  rm -f -- "$(cw_drive_pid_path "$id")" "$(cw_drive_identity_path "$id")" "$(cw_drive_alive_path "$id")"
  cw_mark_once "$(cw_watch_dir "$id")/interrupted-reported" || return 0
  [ "$state" != proven ] || return 0
  task=$(cw_meta_get "$id" task || true)
  url=$(cw_meta_get "$id" pr_url || true)
  line="check: change-watch $task $url interrupted at +${tick}m"
  fm_wake_append check "change-watch-$id-interrupted" "$line" 2>/dev/null \
    || notice "change-watch: could not queue the interruption wake for $url"
}

# A drive whose process is gone without a verdict was killed outright; record
# the interruption at its last heartbeat. The pid counts as the drive only when
# the process behind it still carries the identity the drive recorded at start,
# so a pid reused after a reboot never reads as a live watch.
cw_reconcile_drive() {  # <watch-id>
  local id=$1 pidfile pid recorded at
  pidfile=$(cw_drive_pid_path "$id")
  [ -f "$pidfile" ] || return 0
  cw_watch_done "$id" && return 0
  pid=$(cat "$pidfile" 2>/dev/null || true)
  recorded=$(cat "$(cw_drive_identity_path "$id")" 2>/dev/null || true)
  case "$pid" in
    ''|*[!0-9]*) ;;
    *)
      if [ -n "$recorded" ] && kill -0 "$pid" 2>/dev/null \
        && [ "$(fm_pid_identity "$pid" 2>/dev/null || true)" = "$recorded" ]; then
        return 0
      fi
      ;;
  esac
  at=$(cat "$(cw_drive_alive_path "$id")" 2>/dev/null || true)
  case "$at" in ''|*[!0-9]*) at=$(cw_now) ;; esac
  cw_record_interrupted "$id" "$at"
}

# --- schedule -----------------------------------------------------------------

cw_write_schedule() {  # <watch-id> <t0>
  local id=$1 t0=$2 out='' offset
  for offset in $SCHEDULE_OFFSETS; do
    out="$out$offset	$((t0 + offset))
"
  done
  printf '%s' "$out" | cw_write "$(cw_schedule_path "$id")"
}

cw_next_due_offset() {  # <watch-id> <now>
  local id=$1 now=$2 offset epoch
  while IFS=$'\t' read -r offset epoch; do
    [ -n "$offset" ] || continue
    grep -qx "$offset" "$(cw_sampled_path "$id")" 2>/dev/null && continue
    [ "$now" -ge "$epoch" ] || continue
    printf '%s\n' "$offset"
    return 0
  done < "$(cw_schedule_path "$id")"
  return 1
}

cw_remaining_count() {  # <watch-id>
  local id=$1 offset epoch n=0
  while IFS=$'\t' read -r offset epoch; do
    [ -n "$offset" ] || continue
    grep -qx "$offset" "$(cw_sampled_path "$id")" 2>/dev/null && continue
    n=$((n + 1))
  done < "$(cw_schedule_path "$id")"
  printf '%s\n' "$n"
}

cw_mark_sampled() {  # <watch-id> <offset>
  printf '%s\n' "$2" >> "$(cw_sampled_path "$1")" 2>/dev/null || true
}

cw_watch_done() { [ -f "$(cw_verdict_path "$1")" ]; }

cw_arm() {  # <watch-id> <when-name> <url>
  local id=$1 when_name=$2 url=$3 arm_cmd
  arm_cmd=${FM_CW_ARM_CMD:-$SCRIPT_DIR/fm-procevent-when.sh}
  if [ -x "$arm_cmd" ] || command -v "$arm_cmd" >/dev/null 2>&1; then
    "$arm_cmd" arm "$when_name" \
      --interval 60 --stable 1 --deadline 46800 \
      --condition-timeout 60 --action-timeout 46800 \
      --condition "$SCRIPT_DIR/fm-change-watch.sh" due "$id" \
      --action "$SCRIPT_DIR/fm-change-watch.sh" drive "$id" \
      >/dev/null 2>&1 \
      || notice "change-watch: could not arm the scheduled watch for $url (the watch record is retained)"
  else
    notice "change-watch: arming command unavailable; watch record retained for $url"
  fi
}

# Re-arm a watch that ended interrupted, unmeasurable, absent, or regressed.
cw_rearm() {  # <watch-id> <url>
  local id=$1 url=$2 remaining old attempt when_name arm_cmd state old_verdict
  state=$(cw_row_state "$id")
  [ -n "$state" ] || state=$(cw_rowless_state "$id" | cut -f1)
  old_verdict=$(cat "$(cw_verdict_path "$id")" 2>/dev/null || true)
  if [ -n "$old_verdict" ]; then
    { printf '%s\t%s\n' "$(cw_now)" "$(printf '%s' "$old_verdict" | tr '\n' ' ')"; } \
      >> "$(cw_rearm_history_path "$id")"
  fi
  remaining=$(cw_remaining_count "$id")
  if [ "$remaining" -eq 0 ] || [ "$state" = absent ] || [ "$state" = regressed ]; then
    # A completed schedule has nothing left to sample, so re-arming it would
    # only recompute the same terminal state. Recovery re-measures from now:
    # the readings are taken again and the row goes back to open.
    rm -f -- "$(cw_sampled_path "$id")" "$(cw_verdict_path "$id")" \
      "$(cw_reasons_path "$id")" \
      "$(cw_watch_dir "$id")/noted" "$(cw_watch_dir "$id")/interrupted-reported" \
      "$(cw_watch_dir "$id")/absent-reported"
    : > "$(cw_samples_path "$id")"
    rm -f -- "$(cw_watch_dir "$id")"/last.*
    cw_meta_set "$id" t0 "$(cw_now)"
    cw_write_schedule "$id" "$(cw_now)"
    remaining=$(cw_remaining_count "$id")
  fi
  old=$(cw_meta_get "$id" when_name || true)
  attempt=$(cw_meta_get "$id" arm_attempt || true)
  case "$attempt" in ''|*[!0-9]*) attempt=1 ;; esac
  attempt=$((attempt + 1))
  rm -f -- "$(cw_verdict_path "$id")" "$(cw_watch_dir "$id")/interrupted-reported" \
    "$(cw_watch_dir "$id")/absent-reported" "$(cw_watch_dir "$id")/reported" \
    "$(cw_followup_path "$id")"
  # The watch is in flight again, so its durable row must not keep the
  # interrupted terminal state it just left: a stale terminal row would make the
  # audit report a gap for a watch that is still measuring.
  cw_row_write "$id" open 'the watch is still running'
  arm_cmd=${FM_CW_ARM_CMD:-$SCRIPT_DIR/fm-procevent-when.sh}
  if [ -n "$old" ] && { [ -x "$arm_cmd" ] || command -v "$arm_cmd" >/dev/null 2>&1; }; then
    "$arm_cmd" retire "$old" >/dev/null 2>&1 || true
  fi
  when_name="cw-$(cw_hash "$id/$attempt" | cut -c1-40)"
  {
    printf 'when_name=%s\n' "$when_name"
    printf 'arm_attempt=%s\n' "$attempt"
  } >> "$(cw_meta_path "$id")"
  cw_arm "$id" "$when_name" "$url"
  printf 'change-watch: re-armed %s for %s (%s sample(s) remaining)\n' "$id" "$url" "$remaining"
}

# --- commands -----------------------------------------------------------------

cmd_register() {
  local task=$1 url=$2 provider owner repo number repo_name id derived targets sentries runs
  local notes unread inventory_unread now t0 landed_unread when_name sentry_unreadable row_state row_reason deploy_expected
  local ns deploy carried
  fm_pr_task_id_valid "$task" || die "invalid task id: $task"
  fm_pr_url_parse "$url" || die "invalid pr url: $url"
  provider=$FM_PR_PROVIDER
  owner=${FM_PR_OWNER:-}
  repo=${FM_PR_REPO:-}
  number=$FM_PR_NUMBER
  repo_name=${repo:-}
  [ -n "$repo_name" ] || repo_name=$(basename "${FM_PR_PATH:-$url}")

  id=$(cw_watch_id "$task" "$number")
  if cw_watch_exists "$id"; then
    cw_reconcile_drive "$id"
    row_state=$(cw_row_state "$id")
    if [ "$row_state" = regressed ]; then
      case "$(cw_row_reason "$id")" in
        beta\ regressed*)
          printf 'change-watch: %s ended on a beta regression (%s); it is not re-armed, because re-measuring beta needs a new watch with its own targets\n' \
            "$id" "$(cw_row_reason "$id")"
          return 0 ;;
      esac
    fi
    case "$(cat "$(cw_verdict_path "$id")" 2>/dev/null || true)" in
      interrupted*|unmeasurable-with-reason*|absent*|regressed*) cw_rearm "$id" "$url"; return 0 ;;
    esac
    [ -n "$row_state" ] || row_state=$(cw_rowless_state "$id" | cut -f1)
    case "$row_state" in
      unmeasurable-with-reason|absent|regressed) cw_rearm "$id" "$url"; return 0 ;;
    esac
    printf 'change-watch: %s already registered for %s\n' "$id" "$url"
    return 0
  fi

  cw_kubeconfig_init
  now=$(cw_now)
  t0=$(cw_forge_merge_epoch "$url" "$provider" 2>/dev/null || true)
  case "$t0" in
    ''|*[!0-9]*) t0=$now ;;
  esac
  [ "$t0" -le "$now" ] || t0=$now

  # BETA STAGE FIRST. The beta reading is taken before any production target is
  # read, so a change that breaks something is caught while it is still only in
  # beta. The ordering is the contract, not an accident of layout: nothing below
  # this block may read a production target, and a beta failure returns here
  # without deriving, baselining, or arming a production watch at all.
  beta_out=$(cw_beta_stage "$id" "$repo_name" "$url" "$provider" "$owner" "$repo" "$number" "$t0")
  beta_verdict=$(printf '%s\n' "$beta_out" | awk -F'\t' '$1 == "verdict" { print $2; exit }')
  case "$beta_verdict" in
    beta\ regressed*)
      mkdir -p "$(cw_watch_dir "$id")" || die "cannot create watch directory"
      chmod 0700 "$(cw_watch_dir "$id")" 2>/dev/null || true
      {
        printf 'version=fm-change-watch-v1\n'
        printf 'task=%s\n' "$task"
        printf 'pr_url=%s\n' "$url"
        printf 'watch_id=%s\n' "$id"
        printf 'provider=%s\n' "$provider"
        printf 'owner=%s\n' "$owner"
        printf 'repo=%s\n' "$repo"
        printf 'number=%s\n' "$number"
        printf 't0=%s\n' "$t0"
        printf 'created=%s\n' "$now"
      } | cw_write "$(cw_meta_path "$id")"
      printf '%s\n' "$beta_out" | cw_write "$(cw_beta_path "$id")"
      printf '%s\n' "$beta_verdict" | cw_write "$(cw_verdict_path "$id")"
      cw_row_write "$id" regressed "$beta_verdict"
      cw_report_beta_failure "$id"
      printf 'change-watch: registered %s for %s (beta stage failed: %s; no production target was read and no production watch was armed)\n' \
        "$id" "$url" "$beta_verdict"
      return 0
      ;;
  esac

  derived=$(cw_derive_targets "$url" "$provider" "$owner" "$repo" "$number" "$repo_name" 2>/dev/null || true)
  targets=$(printf '%s\n' "$derived" | awk -F'\t' '$1 == "target" && $2 != "" && $3 != "" { print $2 "\t" $3 }' | sort -u)
  sentries=$(printf '%s\n' "$derived" | awk -F'\t' '$1 == "sentry" && $2 != "" { print $2 }' | sort -u)
  runs=$(printf '%s\n' "$derived" | awk -F'\t' '$1 == "run" && $2 != "" && $3 != "" { print $2 "\t" $3 }' | sort -u)
  notes=$(printf '%s\n' "$derived" | awk -F'\t' '$1 == "note" { print $2 }' | sort -u | paste -sd ';' - | sed 's/;/; /g')
  deploy_expected=yes
  printf '%s\n' "$derived" | grep -qx 'deploy	none' && deploy_expected=no
  # A Sentry project this home cannot authenticate is not a target: keeping it
  # would arm a watch whose every sample reads nothing, and whose end-of-schedule
  # verdict would then read as a clean release.
  sentry_unreadable=''
  if [ -n "$sentries" ] && [ -z "${FM_CW_SENTRY_DIR:-}" ] && ! cw_sentry_vault_ready; then
    notes="$notes${notes:+; }sentry unmeasured: no token in $SENTRY_VAULT"
    sentries=''
    sentry_unreadable=1
  fi
  if [ -z "$targets" ] && [ -z "$sentries" ] && [ -z "$runs" ]; then
    unread=$(printf '%s\n' "$derived" | grep -c '^note	manifest unread: ' || true)
    inventory_unread=$(printf '%s\n' "$derived" | grep -c '^note	image inventory unread: ' || true)
    row_state=not-applicable
    row_reason="no deployable surface touched by $url${notes:+ ($notes)}"
    # The beta stage ran and reached its verdict before this branch, so the reason
    # it measured nothing is stated here rather than left as a silent pass.
    printf 'change-watch: beta stage for %s: %s\n' "$url" "$beta_verdict"
    if ! cw_forge_files "$url" "$provider" "$owner" "$repo" "$number" >/dev/null 2>&1; then
      row_state=unmeasurable-with-reason
      row_reason="the merged file list for $url could not be read"
      printf 'change-watch: cannot read the merged file list for %s; nothing registered\n' "$url"
    elif [ "$unread" -gt 0 ]; then
      row_state=unmeasurable-with-reason
      row_reason="$unread manifest(s) for $url could not be read"
      printf 'change-watch: could not read %s manifest(s) for %s; nothing registered\n' "$unread" "$url"
    elif [ "$inventory_unread" -gt 0 ]; then
      row_state=unmeasurable-with-reason
      row_reason="the image inventory for $url could not be read"
      printf 'change-watch: could not read the image inventory for %s%s; nothing registered\n' "$url" "${notes:+ ($notes)}"
    elif [ -n "$sentry_unreadable" ]; then
      row_state=unmeasurable-with-reason
      row_reason="nothing measurable for $url ($notes)"
      printf 'change-watch: nothing measurable for %s (%s); nothing registered\n' "$url" "$notes"
    elif printf '%s\n' "$notes" | grep -q 'no namespace: '; then
      row_state=unmeasurable-with-reason
      row_reason="a deployable surface for $url could not be watched ($notes)"
      printf 'change-watch: a deployable surface for %s could not be watched (%s); nothing registered\n' "$url" "$notes"
    else
      printf 'change-watch: no deployable service touched by %s%s; nothing registered\n' "$url" "${notes:+ ($notes)}"
    fi
    # Every merge writes one durable row. A merge that touched no deployable
    # surface is not-applicable; one whose surface could not be read is a
    # measurement gap, so the audit never passes a merge nobody could measure.
    # A gap is a watch that ended unmeasurable, so it queues the same wake.
    # This merge has no watch directory to hold a beta record, so its beta reason
    # is carried here explicitly; cw_row_write appends it for every watch-backed
    # row, so the reason is durable rather than only printed.
    row_reason="$row_reason; beta: $beta_verdict"
    cw_row_write "$id" "$row_state" "$row_reason" \
      "$task" "$url" "$t0" "$now" "" "" "$deploy_expected"
    [ "$row_state" != unmeasurable-with-reason ] \
      || cw_queue_unmeasured_wake "$id" "$task" "$url" "$row_reason"
    return 0
  fi

  mkdir -p "$(cw_watch_dir "$id")" || die "cannot create watch directory"
  chmod 0700 "$(cw_watch_dir "$id")" 2>/dev/null || true
  [ -z "$targets" ] || printf '%s\n' "$targets" | cw_write "$(cw_targets_path "$id")"
  [ -z "$sentries" ] || printf '%s\n' "$sentries" | cw_write "$(cw_sentry_path "$id")"
  [ -z "$runs" ] || printf '%s\n' "$runs" | cw_write "$(cw_runs_path "$id")"
  {
    printf 'version=fm-change-watch-v1\n'
    printf 'task=%s\n' "$task"
    printf 'pr_url=%s\n' "$url"
    printf 'watch_id=%s\n' "$id"
    printf 'provider=%s\n' "$provider"
    printf 'owner=%s\n' "$owner"
    printf 'repo=%s\n' "$repo"
    printf 'number=%s\n' "$number"
    printf 't0=%s\n' "$t0"
    printf 'created=%s\n' "$now"
    printf 'deploy_expected=%s\n' "$deploy_expected"
  } | cw_write "$(cw_meta_path "$id")"
  cw_write_schedule "$id" "$t0"
  # The beta record is kept beside the production record so status can state both.
  printf '%s\n' "$beta_out" | cw_write "$(cw_beta_path "$id")"
  # The row exists from registration, so a merge is never unrecorded even if the
  # drive dies before its terminal verdict.
  cw_row_write "$id" open 'the watch is still running'
  cw_capture_baseline "$id" "$t0"
  # The rollout evidence: the images these Deployments run before the release
  # reaches them. A sample scores a target only after they change.
  cw_budget_start
  cw_record_images "$id"
  landed_unread=$(awk -F'\t' '$2 == "" { print $1 }' "$(cw_landed_path "$id")" 2>/dev/null | paste -sd ',' - | sed 's/,/, /g')
  [ -z "$landed_unread" ] \
    || notes="$notes${notes:+; }images unread, so the deploy landing cannot be proven for: $landed_unread"
  # A merge whose deploy already landed before this registration is measured
  # from now rather than awaited: ask each target's gate once here, so the
  # registration itself states it.
  cw_prime_merge_sha "$id"
  while IFS=$'\t' read -r ns deploy; do
    [ -n "${ns:-}" ] || continue
    cw_within_budget || break
    cw_target_landed "$id" "$ns" "$deploy" >/dev/null 2>&1 || true
  done < <(cat "$(cw_targets_path "$id")" 2>/dev/null)
  carried=$(cw_carried_note "$id")
  [ -z "$carried" ] || notes="$notes${notes:+; }$carried"

  when_name="cw-$(cw_hash "$id" | cut -c1-40)"
  {
    printf 'when_name=%s\n' "$when_name"
    printf 'arm_attempt=1\n'
  } >> "$(cw_meta_path "$id")"
  cw_arm "$id" "$when_name" "$url"

  printf 'change-watch: registered %s for %s (%s target(s)%s); beta: %s\n' \
    "$id" "$url" "$(( $(cw_target_ids "$id" | grep -c '' || true) ))" "${notes:+; $notes}" "$beta_verdict"
}

cmd_due() {
  local id=$1 now
  cw_watch_exists "$id" || return 1
  cw_watch_done "$id" && return 1
  now=$(cw_now)
  cw_next_due_offset "$id" "$now" >/dev/null
}

cmd_sample() {
  local id=$1 offset=${2:-} now t0 first metric target value baseline
  cw_watch_exists "$id" || cw_die_unknown_watch "$id"
  now=$(cw_now)
  t0=$(cw_meta_get "$id" t0 || true)
  [ -n "$t0" ] || die "watch $id has no rollout epoch"
  if [ -z "$offset" ]; then
    offset=$(cw_next_due_offset "$id" "$now" || true)
    if [ -z "$offset" ]; then
      offset=$(awk -F'\t' -v now="$now" '$2 <= now { o=$1 } END { if (o != "") print o }' \
        "$(cw_schedule_path "$id")" 2>/dev/null || true)
    fi
    [ -n "$offset" ] || offset=$(awk -F'\t' 'NR == 1 { print $1 }' "$(cw_schedule_path "$id")")
  fi
  first=$(cw_take_sample "$id" "$offset" "$now" "$t0" || true)
  cw_mark_sampled "$id" "$offset"
  [ -z "$first" ] && return 0
  case "$first" in
    absent$'\t'*)
      cw_record_absent "$id" "$offset" "$(printf '%s' "$first" | cut -f2)" \
        "$(printf '%s' "$first" | cut -f3)" "$(printf '%s' "$first" | cut -f4)"
      return 0
      ;;
  esac
  metric=$(printf '%s' "$first" | cut -f1)
  target=$(printf '%s' "$first" | cut -f2)
  value=$(printf '%s' "$first" | cut -f3)
  baseline=$(printf '%s' "$first" | cut -f4)
  cw_record_regression "$id" "$offset" "$metric" "$target" "$value" "$baseline"
  cw_report_regression "$id"
}

CW_DRIVE_ID=''
CW_DRIVE_PIDFILE=''
CW_DRIVE_IDENTITY_FILE=''
CW_SLEEPER=''

cw_drive_interrupted() {
  trap '' TERM INT HUP
  [ -z "$CW_SLEEPER" ] || kill "$CW_SLEEPER" 2>/dev/null || true
  cw_record_interrupted "$CW_DRIVE_ID" "$(cw_now)"
  exit 143
}

cmd_drive() {
  local id=$1 sleep_cmd offset epoch now remaining identity
  cw_watch_exists "$id" || cw_die_unknown_watch "$id"
  sleep_cmd=${FM_CW_SLEEP_CMD:-sleep}
  cw_meta_get "$id" t0 >/dev/null || die "watch $id has no rollout epoch"
  identity=$(fm_pid_identity "$$") || die "cannot read the drive's own process identity"

  CW_DRIVE_ID=$id
  CW_DRIVE_PIDFILE=$(cw_drive_pid_path "$id")
  CW_DRIVE_IDENTITY_FILE=$(cw_drive_identity_path "$id")
  printf '%s\n' "$$" > "$CW_DRIVE_PIDFILE" || die "cannot record the drive pid"
  printf '%s\n' "$identity" > "$CW_DRIVE_IDENTITY_FILE" || die "cannot record the drive identity"
  trap 'cw_pool_memo_clear; rm -f -- "$CW_DRIVE_PIDFILE" "$CW_DRIVE_IDENTITY_FILE"' EXIT
  trap cw_drive_interrupted TERM INT HUP

  while IFS=$'\t' read -r offset epoch; do
    [ -n "$offset" ] || continue
    grep -qx "$offset" "$(cw_sampled_path "$id")" 2>/dev/null && continue
    while :; do
      now=$(cw_now)
      printf '%s\n' "$now" > "$(cw_drive_alive_path "$id")" 2>/dev/null || true
      [ "$now" -ge "$epoch" ] && break
      remaining=$(( epoch - now ))
      [ "$remaining" -gt 60 ] && remaining=60
      "$sleep_cmd" "$remaining" 2>/dev/null &
      CW_SLEEPER=$!
      wait "$CW_SLEEPER" 2>/dev/null || true
      CW_SLEEPER=''
    done
    cmd_sample "$id" "$offset" >/dev/null || true
    if cw_watch_done "$id"; then
      cw_report_regression "$id"
      return 0
    fi
  done < "$(cw_schedule_path "$id")"

  cw_record_completion "$id"
  return 0
}

# The exit status is the done-claim block: an unmeasurable watch is a failure,
# so verdict exits 1 for it and 0 only for clean or regressed. A beta regression
# is a failure too, so it exits 1. A watch still running is not terminal and
# exits 0, because it has not claimed anything yet.
cmd_verdict() {
  local id=$1 line state derived dstate dreason
  if ! cw_watch_exists "$id"; then
    cw_claim_exists "$id" || cw_die_unknown_watch "$id"
    state=$(cw_claim_state "$id")
    printf 'change-watch %s\n' "${state#*$'\t'}"
    case "${state%%$'\t'*}" in
      proven) return 0 ;;
      *) return 1 ;;
    esac
  fi
  cw_reconcile_drive "$id"
  if [ -f "$(cw_verdict_path "$id")" ]; then
    line=$(cat "$(cw_verdict_path "$id")")
    derived=$(cw_rowless_state "$id")
    if [ -n "$derived" ]; then
      dstate=$(printf '%s' "$derived" | cut -f1)
      dreason=$(printf '%s' "$derived" | cut -f2-)
      case "$dstate" in
        proven) line=clean ;;
        regressed) line=$dreason ;;
        *) line="$dstate: $dreason" ;;
      esac
    fi
    printf 'change-watch %s\n' "$line"
    case "$line" in
      unmeasurable-with-reason*|interrupted*|beta\ regressed*|absent*) return 1 ;;
    esac
    return 0
  fi
  cw_verdict_line "$id"
}

# The done-claim gate for one task: exit 0 only when every watch that task
# registered has reached a terminal state that is not a measurement gap. A watch
# still running is not a pass, and an unmeasurable watch is a failure, so a task
# cannot claim done while its merge has no evidence. A task with no watch at all
# passes, because there is nothing to prove.
#
# Both modes decide from the watch's durable row, which the verdict file cannot
# mask: deleting a verdict leaves the row's terminal state intact, so a watch
# that ended unmeasurable keeps failing. A watch registered before rows existed,
# which has no row, is judged by the readings it still holds rather than by its
# verdict file.
#
# --terminal-gap is the same gate for the teardown boundary bin/fm-teardown.sh
# consults: a terminal measurement gap fails there, and so does a regression
# whose follow-up work item has not been recorded, because a watch still running
# outlives the task's records in state/change-watch/ and keeps sampling on its
# own, so refusing teardown for it would block every merge for 12 hours.

# One watch's terminal state derived from the readings on disk, for a watch that
# has no durable row at all. Watches registered before cw_row_write was called at
# registration kept only a samples.log and their own verdict literal, so the
# literal is the sole record of a decision nothing re-derives. Answers nothing
# when the drive has not finished or the directory kept no readings, so every
# caller keeps its own "still running" behaviour instead of inventing a verdict.
cw_rowless_state() {  # <watch-id>
  local id=$1 note derived dstate dreason
  [ -f "$(cw_row_path "$id")" ] && return 0
  cw_watch_exists "$id" || return 0
  [ -f "$(cw_verdict_path "$id")" ] || return 0
  note=$(sed -n 's/^\(interrupted at +[0-9]*m\).*/\1/p' "$(cw_verdict_path "$id")" | head -1)
  derived=$(cw_terminal_state "$id" "$note")
  [ -n "$derived" ] || return 0
  dstate=$(printf '%s' "$derived" | cut -f1)
  dreason=$(printf '%s' "$derived" | cut -f2-)
  printf '%s\t%s\n' "$dstate" "$dreason"
}

cw_followup_recorded() {  # <watch-id>
  local file
  file=$(cw_followup_path "$1")
  [ -s "$file" ] && grep -q '^work_item=' "$file"
}

cw_followup_hint() {  # <watch-id>
  printf 'record the follow-up work item with bin/fm-change-watch.sh followup %s <work-item>' "$1"
}

# One watch's gate decision: 0 passes, 1 fails.
cw_gate_row() {  # <watch-id> <mode>
  local id=$1 mode=${2:-} state line derived
  state=$(cw_row_state "$id")
  if [ -z "$state" ]; then
    line=''
    [ -f "$(cw_verdict_path "$id")" ] && line=$(cat "$(cw_verdict_path "$id")")
    # A watch registered before rows existed kept no row, so its verdict file is
    # the only record of a decision the readings may no longer support. Judge it
    # by the readings it still holds before trusting that literal: directories
    # holding readings that prove their merge sat behind a stale "completed
    # unmeasured" line, which is not a verdict this case can read, so it fell to
    # the catch-all below and failed the gate forever.
    derived=$(cw_rowless_state "$id")
    if [ -n "$derived" ]; then
      case "$derived" in
        proven*) return 0 ;;
        # A derived regression is a measured bad outcome, and it must never
        # inherit the stale literal's pass: the same evidence cannot be a pass
        # here and a failure when a row happens to exist.
        regressed*)
          if [ "$mode" = --terminal-gap ] && cw_followup_recorded "$id"; then
            return 0
          fi
          printf 'change-watch: gate FAIL %s: %s' "$id" \
            "$(printf '%s' "$derived" | cut -f2-)"
          if [ "$mode" = --terminal-gap ]; then
            printf ' (%s)' "$(cw_followup_hint "$id")"
          fi
          printf '\n'
          return 1 ;;
        unmeasurable-with-reason*)
          printf 'change-watch: gate FAIL %s: %s\n' "$id" \
            "$(printf '%s' "$derived" | cut -f2-)"
          return 1 ;;
      esac
    fi
    case "$line" in
      clean|regressed*|not-applicable*) return 0 ;;
      unmeasurable-with-reason*|interrupted*|absent*)
        printf 'change-watch: gate FAIL %s: %s\n' "$id" "$line"; return 1 ;;
      '')
        if [ "$mode" = --terminal-gap ]; then return 0; fi
        printf 'change-watch: gate FAIL %s: still running (%s)\n' "$id" "$(cw_progress_label "$id")"
        return 1 ;;
      *) printf 'change-watch: gate FAIL %s: %s\n' "$id" "$line"; return 1 ;;
    esac
  fi
  case "$state" in
    unmeasurable-with-reason|absent)
      printf 'change-watch: gate FAIL %s: %s: %s\n' \
        "$id" "$state" "$(cw_row_reason "$id")"
      return 1 ;;
    open)
      if [ "$mode" = --terminal-gap ]; then return 0; fi
      if cw_watch_exists "$id"; then
        printf 'change-watch: gate FAIL %s: still running (%s)\n' "$id" "$(cw_progress_label "$id")"
      else
        printf 'change-watch: gate FAIL %s: still running\n' "$id"
      fi
      return 1 ;;
    proven|not-applicable) return 0 ;;
    regressed)
      if [ "$mode" = --terminal-gap ] && cw_followup_recorded "$id"; then
        return 0
      fi
      printf 'change-watch: gate FAIL %s: %s' "$id" "$(cw_row_reason "$id")"
      if [ "$mode" = --terminal-gap ]; then
        printf ' (%s)' "$(cw_followup_hint "$id")"
      fi
      printf '\n'
      return 1 ;;
    *) printf 'change-watch: gate FAIL %s: the durable row records terminal_state %s\n' "$id" "$state"; return 1 ;;
  esac
}

cmd_gate() {  # <task-id> [--terminal-gap]
  local task=$1 mode=${2:-} meta id rc=0 found=0 rows row
  # A pass is a statement about rows this run read. A state root that is not
  # there has no rows to read, and a lane worktree's state/ is exactly that:
  # git never carries it, so the gate run there found nothing and said ok.
  if [ "$CW_STATE_FOUND" -eq 0 ]; then
    printf 'change-watch: gate FAIL for %s: the state root could not be found at %s, so no watch row was read; run the gate with FM_HOME set to the home that owns the task\n' \
      "$task" "$STATE"
    return 1
  fi
  for meta in "$WATCH_ROOT"/*/watch.meta; do
    [ -e "$meta" ] || continue
    id=$(basename "$(dirname "$meta")")
    [ "$(cw_meta_get "$id" task || true)" = "$task" ] || continue
    found=1
    cw_reconcile_drive "$id"
    cw_gate_row "$id" "$mode" || rc=1
  done
  # A merge whose surface could not be read never created a watch directory:
  # its gap lives only in the durable row, so the gate reads the rows too.
  rows=$(cw_rows_dir)
  if [ -d "$rows" ]; then
    for row in "$rows"/*.json; do
      [ -e "$row" ] || continue
      id=$(basename "$row" .json)
      cw_watch_exists "$id" && continue
      [ "$(cw_row_task "$id")" = "$task" ] || continue
      found=1
      cw_gate_row "$id" "$mode" || rc=1
    done
  fi
  if [ "$found" -eq 0 ]; then
    # No watch for this task is a pass only where the root holds the task's own
    # record: a pass must name what it read.
    cw_task_record_exists "$task" && return 0
    printf 'change-watch: gate FAIL for %s: the state root at %s holds no watch row and no record of this task, so nothing for it was read; run the gate with FM_HOME set to the home that owns the task\n' \
      "$task" "$STATE"
    return 1
  fi
  [ "$rc" -ne 0 ] || printf 'change-watch: gate ok for %s\n' "$task"
  return "$rc"
}

cmd_followup() {  # <watch-id> <work-item>
  local id=$1 item=$2 state derived reason
  case "$id" in ''|*[!A-Za-z0-9._-]*) die "invalid watch id: $id" ;; esac
  case "$item" in
    ''|-*|*[!A-Za-z0-9._#/:@+~?=\&%-]*) die "invalid work item: $item" ;;
  esac
  cw_watch_exists "$id" || cw_die_unknown_watch "$id"
  cw_reconcile_drive "$id"
  state=$(cw_row_state "$id")
  if [ -n "$state" ]; then
    [ "$state" = regressed ] \
      || die "change-watch $id is not a recorded regression (terminal_state: $state)"
    reason=$(cw_row_reason "$id")
  else
    derived=$(cw_rowless_state "$id")
    [ "$(printf '%s' "$derived" | cut -f1)" = regressed ] \
      || die "change-watch $id is not a recorded regression"
    reason=$(printf '%s' "$derived" | cut -f2-)
  fi
  {
    printf 'work_item=%s\n' "$item"
    printf 'recorded_epoch=%s\n' "$(cw_now)"
    printf 'reason=%s\n' "$reason"
  } | cw_write "$(cw_followup_path "$id")"
  printf 'change-watch: recorded follow-up %s for %s\n' "$item" "$id"
}

# The 7-day acceptance, measured. It fails when any status log under state/
# carries the literal "change-watch completed unmeasured" line, or when any
# durable row completed inside the window ended unmeasurable-with-reason or
# absent. Both are the same disease: a merge that landed with no evidence it was
# safe.
cmd_audit() {  # [<days>]
  local days=${1:-7} now since rows row state completed hits=0 bad=0 total=0
  case "$days" in ''|*[!0-9]*) die "invalid day count: $days" ;; esac
  now=$(cw_now)
  since=$(( now - days * 86400 ))
  printf 'change-watch audit: window %s day(s) from %s\n' "$days" "$since"
  # An audit of a root that is not there read nothing, which is not a pass.
  if [ "$CW_STATE_FOUND" -eq 0 ]; then
    printf 'change-watch audit: FAIL the state root could not be found at %s, so nothing was read\n' "$STATE"
    return 1
  fi
  if [ -d "$STATE" ]; then
    hits=$(grep -hc 'change-watch completed unmeasured' "$STATE"/*.status 2>/dev/null \
      | awk '{ n += $1 } END { print n + 0 }')
    [ "$hits" -eq 0 ] || grep -l 'change-watch completed unmeasured' "$STATE"/*.status 2>/dev/null \
      | while IFS= read -r row; do printf 'change-watch audit: FAIL %s carries a "completed unmeasured" line\n' "$row"; done
  fi
  rows=$(cw_rows_dir)
  if [ -d "$rows" ]; then
    for row in "$rows"/*.json; do
      [ -e "$row" ] || continue
      total=$((total + 1))
      state=$(cw_row_state "$(basename "$row" .json)")
      completed=$(sed -n 's/.*"completed_epoch": \([0-9]*\).*/\1/p' "$row" 2>/dev/null | tail -1)
      [ -n "$completed" ] || continue
      [ "$completed" -ge "$since" ] || continue
      case "$state" in
        unmeasurable-with-reason|absent)
          bad=$((bad + 1))
          printf 'change-watch audit: FAIL %s ended %s\n' "$(basename "$row" .json)" "$state" ;;
      esac
    done
  fi
  printf 'change-watch audit: %s row(s) recorded, %s unmeasurable or absent in the window, %s "completed unmeasured" status line(s)\n' \
    "$total" "$bad" "$hits"
  [ "$hits" -eq 0 ] && [ "$bad" -eq 0 ] && return 0
  return 1
}

# One status line per watch, with the metrics no sample ever scored and any
# target whose rollout was never proven appended when there are any: a watch is
# never summarized as clean without saying what it did not measure.
cw_status_line() {  # <watch-id>
  local id=$1 gaps unproven line beta carried
  gaps=$(cw_measured_gaps "$id")
  unproven=$(cw_unproven_landing "$id" | paste -sd ',' - | sed 's/,/, /g')
  line=$(cw_verdict_line "$id")
  beta=$(cw_beta_verdict "$id")
  [ -z "$beta" ] || line="$line	beta: $beta"
  [ -z "$gaps" ] || line="$line	unmeasured: $gaps"
  [ -z "$unproven" ] || line="$line	rollout never proven: $unproven"
  carried=$(cw_carried_note "$id")
  [ -z "$carried" ] || line="$line	$carried"
  printf '%s\t%s\n' "$id" "$line"
}

cmd_status() {
  local id=${1:-} meta count=0
  [ "$CW_STATE_FOUND" -eq 1 ] || die "the state root could not be found at $STATE, so no watch was read"
  [ -z "$id" ] || cw_watch_exists "$id" || cw_die_unknown_watch "$id"
  [ -d "$WATCH_ROOT" ] || { printf 'change-watch: no watches registered\n'; return 0; }
  if [ -n "$id" ]; then
    cw_watch_exists "$id" || cw_die_unknown_watch "$id"
    cw_reconcile_drive "$id"
    cw_status_line "$id"
    return 0
  fi
  for meta in "$WATCH_ROOT"/*/watch.meta; do
    [ -e "$meta" ] || continue
    id=$(basename "$(dirname "$meta")")
    cw_reconcile_drive "$id"
    cw_status_line "$id"
    count=$((count + 1))
  done
  [ "$count" -gt 0 ] || printf 'change-watch: no watches registered\n'
}

# The interruption note a row's own reason recorded, so a re-derivation of a
# stopped drive keeps saying the schedule stopped early.
cw_row_interruption() {  # <watch-id>
  cw_row_reason "$1" | sed -n 's/^\(interrupted at +[0-9]*m\).*/\1/p' | head -1
}

# Re-derive the terminal state of rows already on disk from the readings those
# rows and their watch directories still hold. Nothing is invented: a row with no
# watch directory kept no samples to read, and a row still open belongs to a
# drive that has not finished, so both are left exactly as they are.
#
# This exists because the derivation itself was wrong: while cw_terminal_state
# required every reading to score, a single failed +15m read latched an otherwise
# measured watch to unmeasurable-with-reason, and 45 of 82 such rows held the
# readings that proved their merge. Re-running the corrected rule is the only
# honest repair - hand-editing a row would be writing a verdict nobody measured.
#
# Dry run unless --apply: the rewritten corpus is the evidence for the change,
# so it is printed and read before it is written.
cmd_rederive() {
  local apply=0 named=0 id row state derived new reason note completed total=0 changed=0 arg wdir wid
  local rl_total=0 rl_proven=0 rl_regressed=0 rl_unmeasurable=0 run_epoch
  local -a ids=()
  for arg in "$@"; do
    case "$arg" in
      --apply) apply=1 ;;
      -h|--help) usage ;;
      -*) die "unknown option: $arg" ;;
      *) named=1; ids+=("$arg") ;;
    esac
  done
  if [ "$CW_STATE_FOUND" -eq 0 ]; then
    [ "$named" -eq 0 ] || cw_die_unknown_watch "${ids[0]}"
    die "the state root could not be found at $STATE, so no watch row was read"
  fi
  [ "${#ids[@]}" -gt 0 ] || {
    if [ -d "$(cw_rows_dir)" ]; then
      for row in "$(cw_rows_dir)"/*.json; do
        [ -e "$row" ] || continue
        ids+=("$(basename "$row" .json)")
      done
    fi
    # A watch registered before rows were written at registration has no row to
    # enumerate, so the directory itself is the only record of it. Without this
    # the sweep that repairs those watches would never reach one.
    if [ -d "$WATCH_ROOT" ]; then
      for wdir in "$WATCH_ROOT"/*/; do
        [ -d "$wdir" ] || continue
        wid=$(basename "$wdir")
        [ "$wid" = rows ] && continue
        [ -f "$(cw_row_path "$wid")" ] && continue
        ids+=("$wid")
      done
    fi
  }
  printf 'change-watch rederive: %s\n' \
    "$( [ "$apply" -eq 1 ] && printf 'applying' || printf 'dry run, nothing is rewritten (pass --apply to rewrite the rows)' )"
  run_epoch=$(cw_now)
  printf 'change-watch rederive: a row is proven when its +6h reading measured and every Deployment target was measured at least once\n'
  for id in ${ids[@]+"${ids[@]}"}; do
    if [ -f "$(cw_row_path "$id")" ]; then
      total=$((total + 1))
      # A rescored row decided from a reading newer than these samples, whose
      # stale regression flags would only restore the verdict it replaced.
      cw_row_rescored "$id" && continue
      state=$(cw_row_state "$id")
      # A row the old rule called unmeasurable is re-derived, and so is a proven
      # one: the old rule accepted an all-awaiting +6h reading, so a false clean
      # the corrected bar rejects must not be left in place. A regressed row is
      # proof of a bad change and a not-applicable row is already a verdict, so
      # re-reading a later reading's absence would be throwing evidence away; an
      # open row belongs to a drive that has not finished.
      case "$state" in
        unmeasurable-with-reason|proven) ;;
        *) continue ;;
      esac
      cw_watch_exists "$id" || continue
      note=$(cw_row_interruption "$id")
      derived=$(cw_terminal_state "$id" "$note")
      new=$(printf '%s' "$derived" | cut -f1)
      reason=$(printf '%s' "$derived" | cut -f2-)
      [ "$new" != "$state" ] || continue
      changed=$((changed + 1))
      if [ "$changed" -le 10 ]; then
        printf 'rederive: %s: %s -> %s (%s)\n' "$id" "$state" "$new" "$reason"
      fi
      [ "$apply" -eq 1 ] || continue
      completed=$(sed -n 's/.*"completed_epoch": \([0-9]*\).*/\1/p' "$(cw_row_path "$id")" | tail -1)
      cw_row_write "$id" "$new" "$reason" "$(cw_row_task "$id")" \
        "$(cw_row_url "$id")" "" "" "$completed" "$run_epoch"
      case "$new" in
        proven) printf 'clean\n' | cw_write "$(cw_verdict_path "$id")" ;;
        regressed*) printf '%s\n' "$reason" | cw_write "$(cw_verdict_path "$id")" ;;
        unmeasurable-with-reason*) printf 'unmeasurable-with-reason: %s\n' "$reason" | cw_write "$(cw_verdict_path "$id")" ;;
      esac
      continue
    fi
    # No durable row at all. A watch registered before the row was written at
    # registration holds its readings and nothing else, and the gate refuses it on
    # a verdict literal nothing re-derives, so write the row those readings
    # support. The same bar decides: a directory whose readings do not prove the
    # merge gets a row saying so with its reason, which is the honest outcome and
    # still a refusal, never a manufactured pass. A directory with no verdict file
    # belongs to a drive that has not finished and is left alone like an open row.
    cw_watch_exists "$id" || { printf 'rederive: %s: no durable row\n' "$id"; continue; }
    # A row written live wins over a derived one: the derivation runs twice
    # against the same readings, and the second run must leave the first run's
    # bytes exactly as they are rather than restating them with a newer stamp.
    [ -f "$(cw_row_path "$id")" ] && continue
    derived=$(cw_rowless_state "$id")
    [ -n "$derived" ] || { printf 'rederive: %s: no durable row and no readings to judge\n' "$id"; continue; }
    rl_total=$((rl_total + 1))
    total=$((total + 1))
    new=$(printf '%s' "$derived" | cut -f1)
    reason=$(printf '%s' "$derived" | cut -f2-)
    case "$new" in
      proven) rl_proven=$((rl_proven + 1)) ;;
      regressed*) rl_regressed=$((rl_regressed + 1)) ;;
      *) rl_unmeasurable=$((rl_unmeasurable + 1)) ;;
    esac
    changed=$((changed + 1))
    if [ "$changed" -le 10 ]; then
      printf 'rederive: %s: no row -> %s (%s)\n' "$id" "$new" "$reason"
    fi
    [ "$apply" -eq 1 ] || continue
    # The completion epoch is the last reading the directory recorded, so a
    # derived row is measured from when the merge was actually read rather than
    # from when somebody reconstructed the row.
    completed=$(awk -F'\t' '$1 ~ /^[0-9]+$/ && $1 + 0 > m { m = $1 + 0 } END { if (m) print m }' \
      "$(cw_samples_path "$id")" 2>/dev/null)
    cw_row_write "$id" "$new" "$reason" "" "" "" "" "$completed" "$run_epoch"
    case "$new" in
      proven) printf 'clean\n' | cw_write "$(cw_verdict_path "$id")" ;;
      regressed*) printf '%s\n' "$reason" | cw_write "$(cw_verdict_path "$id")" ;;
      unmeasurable-with-reason*) printf 'unmeasurable-with-reason: %s\n' "$reason" | cw_write "$(cw_verdict_path "$id")" ;;
    esac
  done
  if [ "$rl_total" -gt 0 ]; then
    printf 'change-watch rederive: no-row watches: %s proven, %s regressed, %s unmeasurable with reason, %s total\n' \
      "$rl_proven" "$rl_regressed" "$rl_unmeasurable" "$rl_total"
  fi
  if [ "$apply" -eq 1 ]; then
    printf 'change-watch rederive: %s row(s) rewritten of %s row(s) read\n' "$changed" "$total"
  else
    printf 'change-watch rederive: %s row(s) would change of %s row(s) read\n' "$changed" "$total"
  fi
}

# One reading against its recorded baseline, under the rule rescore applies:
# "unmeasured" when the baseline was never read and the bar is relative to it
# (or is deploy_run), "unchanged" when the reading equals a baseline whose bar
# reads it (or is deploy_run), and otherwise the metric's own bar decides
# "regressed" or "within-bar" - so an absolute metric re-read equal to its
# baseline is still judged by its bar. A baseline that was never read is not 0,
# and a reading that did not move did not regress, so neither can ever be scored
# as a regression here.
cw_rescore_compare() {  # <metric> <value> <baseline> <previous>
  local metric=$1 value=$2 baseline=$3 previous=$4
  if [ -z "$baseline" ]; then
    case "$metric" in
      # Absolute bars never read the baseline, so its absence decides nothing.
      oomkilled|rss_ratio|pgbouncer_cl_waiting) ;;
      *) printf 'unmeasured\n'; return 0 ;;
    esac
  elif cw_metric_relative "$metric" || [ "$metric" = deploy_run ]; then
    if awk -v v="$value" -v b="$baseline" 'BEGIN { exit !((v + 0) == (b + 0)) }'; then
      printf 'unchanged\n'
      return 0
    fi
  fi
  if cw_metric_regressed "$metric" "$value" "$baseline" "$previous"; then
    printf 'regressed\n'
  else
    printf 'within-bar\n'
  fi
}

# The metric key a regressed or absent row's verdict rests on: the one a prior
# rescore recorded, else the regression record's, else the failed deploy run an
# absent row was decided by. Prints nothing when the row names none.
cw_rescore_key() {  # <watch-id>
  local id=$1 key metric target
  key=$(sed -n 's/.*"rescore": {"epoch": [0-9]*, "key": "\([^"]*\)".*/\1/p' "$(cw_row_path "$id")" 2>/dev/null | tail -1)
  if [ -z "$key" ]; then
    metric=$(cw_regression_field "$id" metric)
    target=$(cw_regression_field "$id" target)
    [ -z "$metric" ] || [ -z "$target" ] || key="$metric@$target"
  fi
  if [ -z "$key" ]; then
    key=$(awk -F'\t' '$3 ~ /^deploy_run@/ && $7 == 1 && $4 != "" && ($4 + 0) < 1 { k = $3 } END { if (k != "") print k }' \
      "$(cw_samples_path "$id")" 2>/dev/null)
  fi
  [ -z "$key" ] || printf '%s\n' "$key"
}

cw_rescore_refuse() {  # <watch-id> <reason>
  printf 'change-watch rescore: refused %s: %s\n' "$1" "$2" >&2
  exit 1
}

# The deciding metric read again now, with the reader a live sample uses.
# Prints the numeric value, or fails with the reason it could not be read.
cw_rescore_read() {  # <watch-id> <metric> <target> <t0>
  local id=$1 metric=$2 target=$3 t0=$4 cluster='' value='' reason='' err rc=0
  cw_budget_start
  case "$metric" in
    sentry_new_issues|deploy_run) ;;
    *) cluster=$(cw_cluster_probe || true) ;;
  esac
  cw_prime_merge_sha "$id"
  CW_SAMPLE_BLOCKER_REASON=''
  cw_sample_blocker "$id" "$metric" "$target" "$cluster" || true
  reason=$CW_SAMPLE_BLOCKER_REASON
  if [ -z "$reason" ]; then
    err=$(mktemp "${TMPDIR:-/tmp}/fm-cw-rescore.XXXXXX" 2>/dev/null) || err=/dev/null
    value=$(cw_metric_read "$id" "$metric" "$target" sample "$t0" 2>"$err") || rc=$?
    if [ "$rc" -ne 0 ] || ! printf '%s' "$value" | grep -qE '^-?[0-9]+([.][0-9]+)?$'; then
      if [ -n "$value" ] && ! printf '%s' "$value" | grep -qE '^-?[0-9]+([.][0-9]+)?$'; then
        reason=$value
      else
        reason=$(tail -1 "$err" 2>/dev/null | cut -c1-200)
        [ -n "$reason" ] || reason="read exited $rc with no value"
      fi
      value=''
    fi
    [ "$err" = /dev/null ] || rm -f -- "$err" 2>/dev/null || true
  fi
  cw_pool_memo_clear
  if [ -z "$value" ]; then
    printf '%s\n' "$reason"
    return 1
  fi
  printf '%s\n' "$value"
}

cmd_rescore() {  # [--apply] <watch-id>
  local apply=0 id='' arg state prior key metric target baseline previous value
  local t0 now cmp desc other='' new derived reason completed rj keys
  local s_offset s_key s_value s_baseline s_scored s_prev prevs=''
  for arg in "$@"; do
    case "$arg" in
      --apply) apply=1 ;;
      -h|--help) usage ;;
      -*) die "unknown option: $arg" ;;
      *) [ -z "$id" ] || usage; id=$arg ;;
    esac
  done
  [ -n "$id" ] || usage
  case "$id" in *[!A-Za-z0-9._-]*) die "invalid watch id: $id" ;; esac
  [ "$CW_STATE_FOUND" -eq 1 ] || cw_rescore_refuse "$id" "the state root could not be found at $STATE"
  [ -f "$(cw_row_path "$id")" ] \
    || cw_rescore_refuse "$id" "no durable row at $(cw_row_path "$id")"
  state=$(cw_row_state "$id")
  case "$state" in
    regressed|absent) ;;
    open) cw_rescore_refuse "$id" "the row is still open: its drive has not finished" ;;
    *) cw_rescore_refuse "$id" "the row records ${state:-no terminal state}, which rests on no single reading (rederive owns a readings-only repair)" ;;
  esac
  cw_watch_exists "$id" \
    || cw_rescore_refuse "$id" "no watch directory under $WATCH_ROOT, so the metric cannot be re-read"
  key=$(cw_rescore_key "$id")
  [ -n "$key" ] || cw_rescore_refuse "$id" "the row names no deciding metric"
  metric=$(cw_key_metric "$key")
  target=$(cw_key_target "$key")
  t0=$(cw_meta_get "$id" t0 || true)
  [ -n "$t0" ] || cw_rescore_refuse "$id" "the watch has no rollout epoch"
  prior=$(cw_row_reason "$id" | sed 's/\\"/"/g; s/\\\\/\\/g')
  baseline=$(cw_baseline_value "$id" "$key" 2>/dev/null || true)
  # The same carried-baseline rule a live sample applies (cw_take_sample).
  case "$metric" in
    restarts|http_5xx_per_min)
      if awk -F'\t' -v t="$target" '$1 == t { found = 1 } END { exit(found ? 0 : 1) }' \
        "$(cw_carried_path "$id")" 2>/dev/null; then
        baseline=0
      fi
      ;;
  esac
  previous=$(awk -F'\t' -v k="$key" '$3 == k && $4 != "" { v = $4 } END { print v }' \
    "$(cw_samples_path "$id")" 2>/dev/null)
  if ! value=$(cw_rescore_read "$id" "$metric" "$target" "$t0"); then
    cw_rescore_refuse "$id" "$key cannot be re-read now: ${value:-no reason given}; no reading is no verdict"
  fi
  now=$(cw_now)
  cmp=$(cw_rescore_compare "$metric" "$value" "$baseline" "$previous")
  desc="$key re-read $value vs baseline ${baseline:-unmeasured} ($cmp) at $now"
  # Every other recorded reading is re-scored under the same comparison, so a
  # real regression elsewhere in the watch is never lost with the stale one.
  while IFS=$'\t' read -r _ s_offset s_key s_value s_baseline _ s_scored _; do
    [ -n "${s_key:-}" ] && [ "$s_key" != "$key" ] || continue
    s_prev=$(printf '%s' "$prevs" | awk -F'\t' -v k="$s_key" '$1 == k { v = $2 } END { print v }')
    if [ "${s_scored:-0}" = 1 ] && [ -n "$s_value" ] \
      && [ "$(cw_rescore_compare "$(cw_key_metric "$s_key")" "$s_value" "$s_baseline" "$s_prev")" = regressed ]; then
      other="regressed at +$((s_offset / 60))m on $s_key ($s_value vs baseline ${s_baseline:-unmeasured})"
      break
    fi
    [ -z "$s_value" ] || prevs="$prevs$s_key"$'\t'"$s_value"$'\n'
  done < <(cat "$(cw_samples_path "$id")" 2>/dev/null)
  keys=$(cw_metric_keys "$id" | sort -u)
  if [ "$cmp" = regressed ]; then
    new=regressed
    reason="regressed on rescore: $desc"
  elif [ -n "$other" ]; then
    new=regressed
    reason="$other; rescored: $desc"
  elif cw_metric_absent "$metric" "$value"; then
    new=absent
    reason="absent on rescore: the deploy run carrying the merge failed on $target ($desc), so the change is not in production"
  elif [ "$metric" = deploy_run ] && [ "$keys" = "$key" ] && [ "$now" -ge $((t0 + 21600)) ]; then
    # deploy_run's bar is the run's own conclusion and never reads the
    # baseline, so an unmeasured baseline decides nothing here.
    new=proven
    reason="rescored: $desc, the watch's only metric, read after +6h: the deploy run carrying the merge succeeded"
  elif [ "$cmp" != unmeasured ] && [ "$keys" = "$key" ] && [ "$now" -ge $((t0 + 21600)) ]; then
    new=proven
    reason="rescored: $desc, the watch's only metric, read after +6h"
  else
    derived=$(cw_terminal_state "$id" "$(cw_row_interruption "$id")" 1)
    new=$(printf '%s' "$derived" | cut -f1)
    reason="rescored: $desc; $(printf '%s' "$derived" | cut -f2-)"
  fi
  printf 'change-watch rescore: %s\n' \
    "$( [ "$apply" -eq 1 ] && printf 'applying' || printf 'dry run, nothing is rewritten (pass --apply to rewrite the row)' )"
  printf 'rescore: %s: %s -> %s (%s)\n' "$id" "$state" "$new" "$reason"
  [ "$apply" -eq 1 ] || return 0
  rj=$(printf '{"epoch": %s, "key": %s, "value": %s, "baseline": %s, "comparison": %s, "prior_state": %s, "prior_reason": %s}' \
    "$now" "$(cw_json_string "$key")" "$(cw_json_string "$value")" "$(cw_json_or_null "$baseline")" \
    "$(cw_json_string "$cmp")" "$(cw_json_string "$state")" "$(cw_json_string "$prior")")
  completed=$(sed -n 's/.*"completed_epoch": \([0-9]*\).*/\1/p' "$(cw_row_path "$id")" | tail -1)
  cw_row_write "$id" "$new" "$reason" "$(cw_row_task "$id")" "$(cw_row_url "$id")" "" "" "$completed" "" "" "$rj"
  case "$new" in
    proven) printf 'clean\n' | cw_write "$(cw_verdict_path "$id")" ;;
    regressed|absent) printf '%s\n' "$reason" | cw_write "$(cw_verdict_path "$id")" ;;
    *) printf '%s: %s\n' "$new" "$reason" | cw_write "$(cw_verdict_path "$id")" ;;
  esac
  printf 'change-watch rescore: %s rewritten %s -> %s\n' "$id" "$state" "$new"
}

# One pool console read for the doctor: a stated ok or FAIL line, never silence.
cw_doctor_pool() {  # <label> <host> <port> <database>
  local label=$1 host=$2 port=$3 db=$4 where err out rc reason rows
  where="${label:+$label }pool read $POOLER_SSH_USER@$host:$port"
  err=$(mktemp "${TMPDIR:-/tmp}/fm-cw-doctor.XXXXXX" 2>/dev/null) || err=/dev/null
  cw_budget_start
  out=$(cw_pool_console "$host" "$port" 2>"$err")
  rc=$?
  reason=$(tail -1 "$err" 2>/dev/null || true)
  [ "$err" = /dev/null ] || rm -f -- "$err"
  if [ "$rc" -eq 124 ]; then
    printf 'doctor: FAIL %s: timed out after %ss\n' "$where" "$SAMPLE_DEADLINE_SECONDS"
    return 1
  fi
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    printf 'doctor: FAIL %s: %s\n' "$where" "${reason:-exit $rc with no rows}"
    return 1
  fi
  rows=$(printf '%s\n' "$out" | awk -F'|' -v db="$db" '
    NR == 1 { for (i = 1; i <= NF; i++) if ($i == "database") d = i; next }
    NF > 1 && (db == "" || (d && $d == db)) { n++ }
    END { print n + 0 }
  ')
  if [ "$rows" -eq 0 ]; then
    printf 'doctor: FAIL %s: no pool row%s\n' "$where" "${db:+ for database $db}"
    return 1
  fi
  printf 'doctor: ok %s returned %s pool row(s)%s\n' "$where" "$rows" "${db:+ for database $db}"
}

# The doctor's two halves: the cluster read path itself, then every target's own
# live read. Each line is a stated ok or FAIL, so an unmeasured watch never has to
# be diagnosed by re-reading its samples by hand.
cw_doctor_open_target() {  # <ns> <deploy>
  local ns=$1 deploy=$2 target="$1/$2" images
  if images=$(cw_live_images "$ns" "$deploy" 2>/dev/null) && [ -n "$images" ]; then
    printf 'doctor: ok %s pods read, images %s\n' "$target" "$images"
    return 0
  fi
  printf 'doctor: FAIL %s pods unreadable through %s\n' "$target" "${CW_KUBECONFIG:-the ambient kubectl default}"
  return 1
}

cw_doctor_reasons() {  # <watch-id>
  local id=$1 lines
  lines=$(awk -F'\t' '$2 != "" { printf "%s: %s\n", $1, $2 }' "$(cw_reasons_path "$id")" 2>/dev/null | head -20 || true)
  [ -n "$lines" ] || return 0
  printf '%s\n' "$lines" | while IFS= read -r line; do
    case "$line" in
      # A wait the watch expects to end by itself is reported as a wait, so a
      # doctor run between the merge and the rollout does not read as breakage.
      *"awaiting the deploy"*|*"no "*"run since the merge"*|*"no run created at or after the merge"*|*"run in flight"*)
        printf 'doctor: awaiting %s\n' "$line" ;;
      *) printf 'doctor: last read FAIL %s\n' "$line" ;;
    esac
  done
}

cmd_doctor() {
  local id=${1:-} ns deploy target spec failed=0 project run_repo workflow value last
  cw_kubeconfig_init
  printf 'doctor: kubeconfig %s (%s)\n' "${CW_KUBECONFIG:-ambient kubectl default}" "$CW_KUBECONFIG_SOURCE"
  if probe=$(cw_cluster_probe); then
    printf 'doctor: ok cluster answers\n'
  else
    printf 'doctor: FAIL cluster unreachable: %s\n' "$probe"
    failed=1
  fi
  if [ -z "$id" ]; then
    cw_doctor_pool '' "$POOLER_DEFAULT_HOST" "$POOLER_DEFAULT_PORT" '' || failed=1
    return "$failed"
  fi
  cw_watch_exists "$id" || cw_die_unknown_watch "$id"
  cw_budget_start
  if [ -f "$(cw_targets_path "$id")" ]; then
    while IFS=$'\t' read -r ns deploy; do
      [ -n "${ns:-}" ] || continue
      target="$ns/$deploy"
      cw_doctor_open_target "$ns" "$deploy" || failed=1
      if spec=$(cw_pool_spec "$id" "$target"); then
        cw_doctor_pool "$target" "$(printf '%s' "$spec" | cut -f1)" \
          "$(printf '%s' "$spec" | cut -f2)" "$(printf '%s' "$spec" | cut -f3)" || failed=1
      else
        printf 'doctor: FAIL %s pool unresolved; its pool metric is unmeasured for the whole watch\n' "$target"
        failed=1
      fi
    done < "$(cw_targets_path "$id")"
  fi
  if [ -f "$(cw_sentry_path "$id")" ]; then
    while IFS= read -r project; do
      [ -n "$project" ] || continue
      if value=$(cw_live_sentry_new_issues "$project" "$(($(cw_now) - 86400))" 2>&1) \
        && printf '%s' "$value" | grep -qE '^[0-9]+$'; then
        printf 'doctor: ok sentry/%s read %s new error issue(s) in the last 24h\n' "$project" "$value"
      else
        printf 'doctor: FAIL sentry/%s unreadable: %s\n' "$project" "$(printf '%s' "$value" | tail -1)"
        failed=1
      fi
    done < "$(cw_sentry_path "$id")"
  fi
  if [ -f "$(cw_runs_path "$id")" ]; then
    while IFS=$'\t' read -r run_repo workflow; do
      [ -n "${run_repo:-}" ] || continue
      cw_budget_start
      if value=$(cw_live_deploy_run "$run_repo" "$workflow" "$(cw_meta_get "$id" t0 || true)" \
        "$(cw_merge_sha "$id")" 2>&1) \
        && printf '%s' "$value" | grep -qE '^[01]$'; then
        printf 'doctor: ok run/%s#%s read %s\n' "$run_repo" "$workflow" "$value"
      else
        last=$(printf '%s' "$value" | tail -1)
        case "$last" in
          "awaiting the deploy:"*|"no "*run*|*"in flight"*)
            printf 'doctor: awaiting run/%s#%s: %s\n' "$run_repo" "$workflow" "$last" ;;
          *)
            printf 'doctor: FAIL run/%s#%s unreadable: %s\n' "$run_repo" "$workflow" "$last"
            failed=1 ;;
        esac
      fi
    done < "$(cw_runs_path "$id")"
  fi
  cw_doctor_reasons "$id"
  return "$failed"
}

# --- claim rows ---------------------------------------------------------------
#
# A claim row is the durable row of a worker's done claim, registered at CLAIM
# time, before any PR exists, so its pr_url may be null. Its evidence is the
# task's acceptance probe: a hash-bound script that reads the live consumer
# surface and exits 0 only when the change is there. `acceptance` re-hashes the
# bound probe, runs it from / under a clean environment with a bounded timeout,
# and records the result. The claim record lives beside the rows in
# state/change-watch/claims/<watch-id>.meta (key=value) and .log
# ("<epoch><TAB><offset><TAB><exit>"), and the row is rewritten from them.
#
# A claim row is proven the first time its probe exits 0, absent when the probe
# still fails at the last claim offset, and open until then. Its deadline is
# claimed_epoch + CLAIM_DEADLINE_SECS; an open row past it is what the landing
# police pages on.
CLAIM_OFFSETS="0 900 3600 21600"
# The scope's runner step pages when a claim row is past this deadline unproven,
# and the follow-up landing police reads the deadline column from `claims`.
CLAIM_DEADLINE_SECS=${FM_CW_CLAIM_DEADLINE_SECS:-3600}
case "$CLAIM_DEADLINE_SECS" in ''|*[!0-9]*) CLAIM_DEADLINE_SECS=3600 ;; esac

cw_claims_dir() { printf '%s/claims\n' "$WATCH_ROOT"; }
cw_claim_id() { printf '%s-claim\n' "$1"; }
cw_claim_meta_path() { printf '%s/%s.meta\n' "$(cw_claims_dir)" "$1"; }
cw_claim_log_path() { printf '%s/%s.log\n' "$(cw_claims_dir)" "$1"; }
cw_claim_exists() { [ -f "$(cw_claim_meta_path "$1")" ]; }

cw_claim_get() {  # <watch-id> <key>
  grep "^$2=" "$(cw_claim_meta_path "$1")" 2>/dev/null | tail -1 | cut -d= -f2-
}

cw_file_sha256() {  # <file>
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

# The claim's state from its log, as "<state>\t<reason>".
cw_claim_state() {  # <watch-id>
  local id=$1
  awk -F'\t' -v final="${CLAIM_OFFSETS##* }" '
    $3 == 0 && !proven { proven = 1; at = $2 }
    { last = $3; lastoff = $2; if ($2 == final) finalfail = ($3 != 0) }
    END {
      if (proven) { printf "proven\tthe acceptance probe exited 0 at +%dm\n", at / 60; exit }
      if (finalfail) { printf "absent\tthe acceptance probe still exited %s at +%dm, the last reading\n", last, lastoff / 60; exit }
      if (last != "") { printf "open\tthe acceptance probe exited %s at +%dm\n", last, lastoff / 60; exit }
      printf "open\tthe acceptance probe has not run yet\n"
    }
  ' "$(cw_claim_log_path "$id")" 2>/dev/null
}

cw_claim_row_write() {  # <watch-id>
  local id=$1 task url claimed probe sha state reason completed readings offset reading
  local last_exit last_epoch
  task=$(cw_claim_get "$id" task)
  url=$(cw_claim_get "$id" pr_url)
  claimed=$(cw_claim_get "$id" claimed_epoch)
  probe=$(cw_claim_get "$id" probe_path)
  sha=$(cw_claim_get "$id" sha256)
  state=$(cw_claim_state "$id")
  reason=${state#*$'\t'}
  state=${state%%$'\t'*}
  case "$state" in
    open) completed=null ;;
    *) completed=$(cw_now) ;;
  esac
  readings=''
  for offset in $CLAIM_OFFSETS; do
    reading=$(awk -F'\t' -v o="$offset" '$2 == o { line = sprintf("{\"at\": %s, \"exit\": %s}", $1, $3) } END { if (line != "") printf "%s", line }' \
      "$(cw_claim_log_path "$id")" 2>/dev/null)
    readings="$readings${readings:+, }\"$offset\": ${reading:-null}"
  done
  last_exit=$(awk -F'\t' 'END { print $3 }' "$(cw_claim_log_path "$id")" 2>/dev/null)
  last_epoch=$(awk -F'\t' 'END { print $1 }' "$(cw_claim_log_path "$id")" 2>/dev/null)
  mkdir -p "$(cw_rows_dir)" 2>/dev/null || true
  chmod 0700 "$(cw_rows_dir)" 2>/dev/null || true
  {
    printf '{"version": "fm-change-watch-row-v1"'
    printf ', "kind": "claim"'
    printf ', "watch_id": %s' "$(cw_json_string "$id")"
    printf ', "task": %s' "$(cw_json_string "$task")"
    printf ', "pr_url": %s' "$(cw_json_or_null "$url")"
    printf ', "merge_epoch": null'
    printf ', "registered_epoch": %s' "${claimed:-null}"
    printf ', "deadline_epoch": %s' "$(( ${claimed:-0} + CLAIM_DEADLINE_SECS ))"
    printf ', "completed_epoch": %s' "$completed"
    printf ', "readings": {%s}' "$readings"
    printf ', "acceptance": {"probe_path": %s, "sha256": %s, "last_exit": %s, "last_epoch": %s}' \
      "$(cw_json_string "$probe")" "$(cw_json_string "$sha")" "${last_exit:-null}" "${last_epoch:-null}"
    printf ', "real_user_check": "not-applicable"'
    printf ', "real_user_reason": "a claim is proven by its acceptance probe"'
    printf ', "unmeasured_metrics": ""'
    printf ', "unproven_targets": ""'
    printf ', "terminal_state": %s' "$(cw_json_string "$state")"
    printf ', "reason": %s}\n' "$(cw_json_string "$reason")"
  } | cw_write "$(cw_row_path "$id")" \
    || notice "change-watch: could not write the durable row for $id"
}

# Register a done claim: bind the task's acceptance probe by its sha256 and
# write an open row. Claiming again replaces the claim, its readings, and its
# binding, because a worker that fixes its change claims again.
cmd_claim() {  # <task-id> <probe-path> [<pr-url>]
  local task=$1 probe=$2 url=${3:-} id sha now
  fm_pr_task_id_valid "$task" || die "invalid task id: $task"
  [ -z "$url" ] || fm_pr_url_parse "$url" || die "invalid pr url: $url"
  case "$probe" in /*) ;; *) die "the acceptance probe path must be absolute: $probe" ;; esac
  [ -f "$probe" ] && [ ! -L "$probe" ] || die "no acceptance probe file at $probe"
  [ -x "$probe" ] || die "the acceptance probe is not executable: $probe"
  sha=$(cw_file_sha256 "$probe") || die "cannot hash the acceptance probe: $probe"
  [ -n "$sha" ] || die "cannot hash the acceptance probe: $probe"
  id=$(cw_claim_id "$task")
  now=$(cw_now)
  mkdir -p "$(cw_claims_dir)" || die "cannot create the claims directory"
  chmod 0700 "$(cw_claims_dir)" 2>/dev/null || true
  {
    printf 'version=fm-change-watch-claim-v1\n'
    printf 'task=%s\n' "$task"
    printf 'pr_url=%s\n' "$url"
    printf 'claimed_epoch=%s\n' "$now"
    printf 'probe_path=%s\n' "$probe"
    printf 'sha256=%s\n' "$sha"
  } | cw_write "$(cw_claim_meta_path "$id")" || die "cannot write the claim record"
  : | cw_write "$(cw_claim_log_path "$id")" || die "cannot reset the claim readings"
  cw_claim_row_write "$id"
  printf 'change-watch: claimed %s for %s (probe %s sha256 %s)\n' "$id" "$task" "$probe" "$sha"
}

# Run the claim's bound probe and record its exit status. The probe is re-hashed
# against the claim's binding and must still be a regular, non-symlink,
# executable file; a changed probe records 125 without being run. A claim that is
# already proven or absent is terminal and is left unchanged. A newly absent
# claim queues one check wake.
cw_claim_probe_run() {  # <probe>
  local probe=$1 limit=${FM_CW_CLAIM_PROBE_TIMEOUT:-5}
  case "$limit" in ''|*[!0-9]*) limit=5 ;; esac
  if command -v timeout >/dev/null 2>&1; then
    (cd / && env -i HOME="$HOME" PATH="$PATH" timeout "$limit" "$probe")
  elif command -v perl >/dev/null 2>&1; then
    (cd / && env -i HOME="$HOME" PATH="$PATH" perl -e 'alarm shift; exec @ARGV' "$limit" "$probe")
  else
    return 125
  fi
}

cmd_acceptance() {  # <watch-id> <offset-seconds>
  local id=$1 offset=$2 before after task url probe sha current code
  [ "$CW_STATE_FOUND" -eq 1 ] || die "unknown claim: $id (the state root could not be found at $STATE)"
  cw_claim_exists "$id" || die "unknown claim: $id"
  case " $CLAIM_OFFSETS " in *" $offset "*) ;; *) die "not a claim offset: $offset (one of: $CLAIM_OFFSETS)" ;; esac
  before=$(cw_claim_state "$id")
  before=${before%%$'\t'*}
  if [ "$before" != open ]; then
    printf 'change-watch: %s already %s\n' "$id" "$before"
    return 0
  fi
  probe=$(cw_claim_get "$id" probe_path)
  sha=$(cw_claim_get "$id" sha256)
  code=125
  if [ -f "$probe" ] && [ ! -L "$probe" ] && [ -x "$probe" ]; then
    current=$(cw_file_sha256 "$probe" || true)
    if [ -n "$current" ] && [ "$current" = "$sha" ]; then
      cw_claim_probe_run "$probe"
      code=$?
    fi
  fi
  printf '%s\t%s\t%s\n' "$(cw_now)" "$offset" "$code" >> "$(cw_claim_log_path "$id")" \
    || die "cannot record the acceptance reading for $id"
  cw_claim_row_write "$id"
  after=$(cw_claim_state "$id")
  if [ "${after%%$'\t'*}" = absent ]; then
    task=$(cw_claim_get "$id" task)
    url=$(cw_claim_get "$id" pr_url)
    fm_wake_append check "change-watch-$id-absent" \
      "check: change-watch $task ${url:-claim} absent (${after#*$'\t'})" 2>/dev/null \
      || notice "change-watch: could not queue the absent wake for $id"
  fi
  printf 'change-watch: %s %s: %s\n' "$id" "${after%%$'\t'*}" "${after#*$'\t'}"
}

# Every open claim, one tab-separated line each:
#   <watch-id> <task> <claimed-epoch> <probe-path> <sha256> <due-offset|-> <last-exit|-> <deadline-epoch>
# <due-offset> is the latest claim offset that has come due and has no reading
# yet, so a runner that missed several offsets takes one reading, not a burst.
cmd_claims() {
  local meta id claimed due now offset last state
  [ "$CW_STATE_FOUND" -eq 1 ] || die "the state root could not be found at $STATE, so no claim was read"
  now=$(cw_now)
  [ -d "$(cw_claims_dir)" ] || return 0
  for meta in "$(cw_claims_dir)"/*.meta; do
    [ -e "$meta" ] || continue
    id=$(basename "$meta" .meta)
    state=$(cw_claim_state "$id")
    [ "${state%%$'\t'*}" = open ] || continue
    claimed=$(cw_claim_get "$id" claimed_epoch)
    due=-
    for offset in $CLAIM_OFFSETS; do
      [ "$now" -ge $(( claimed + offset )) ] || break
      if ! awk -F'\t' -v o="$offset" '$2 == o { found = 1 } END { exit !found }' "$(cw_claim_log_path "$id")" 2>/dev/null; then
        due=$offset
      fi
    done
    last=$(awk -F'\t' 'END { print $3 }' "$(cw_claim_log_path "$id")" 2>/dev/null)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$(cw_claim_get "$id" task)" "$claimed" \
      "$(cw_claim_get "$id" probe_path)" "$(cw_claim_get "$id" sha256)" "$due" "${last:--}" \
      "$(( claimed + CLAIM_DEADLINE_SECS ))"
  done
}

# --- entry --------------------------------------------------------------------

# Every command that reads the cluster resolves the kubeconfig first, so a
# by-hand reproduction and the armed watch read the same cluster.
cw_kubeconfig_init
trap cw_pool_memo_clear EXIT

case "${1:-}" in
  register) [ "$#" -eq 3 ] || usage; shift; cmd_register "$@" ;;
  due) [ "$#" -eq 2 ] || usage; shift; cmd_due "$@" ;;
  drive) [ "$#" -eq 2 ] || usage; shift; cmd_drive "$@" ;;
  sample) if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then usage; fi; shift; cmd_sample "$@" ;;
  verdict) [ "$#" -eq 2 ] || usage; shift; cmd_verdict "$@" ;;
  gate) [ "$#" -eq 2 ] || [ "$#" -eq 3 ] || usage; shift; cmd_gate "$@" ;;
  followup) [ "$#" -eq 3 ] || usage; shift; cmd_followup "$@" ;;
  audit) [ "$#" -le 2 ] || usage; shift; cmd_audit "$@" ;;
  status) [ "$#" -le 2 ] || usage; shift; cmd_status "$@" ;;
  rederive) shift; cmd_rederive "$@" ;;
  rescore) [ "$#" -ge 2 ] && [ "$#" -le 3 ] || usage; shift; cmd_rescore "$@" ;;
  doctor) [ "$#" -le 2 ] || usage; shift; cmd_doctor "$@" ;;
  claim) [ "$#" -eq 3 ] || [ "$#" -eq 4 ] || usage; shift; cmd_claim "$@" ;;
  acceptance) [ "$#" -eq 3 ] || usage; shift; cmd_acceptance "$@" ;;
  claims) [ "$#" -eq 1 ] || usage; cmd_claims ;;
  ""|-h|--help|help) usage ;;
  *) usage ;;
esac
