# the 80% task-cap page: before and after 70f9a413

Fixture: the real 2026-11-14 hierarchy - app.slice (9200 tasks) above three
transient tmux pane scopes (8200/760/240), slice at 10000 of 12000 (83%).

## before (638fc6e1, the globs) - the aggregate is named, no scope is
# ak47 PAGE 4:24 AM ET (2026-11-14T09:24:49Z)

user task cap 83% used (10000 of 12000 tasks for uid aaron) - holders: app(9200) session(800) - past 100% every fork fails EAGAIN and the fleet stops starting; the slice cap is tasksmax-slice.conf and the per-unit cap is /etc/systemd/user.conf.d/60-ak47-tasksmax-user.conf - find the lane that grew: ~/.local/state/ak47/tasks-latest.md

samples: ~/.local/state/ak47/samples.log | findings: health-latest.md

## after (70f9a413) - every holder is a leaf scope with its own count
# ak47 PAGE 4:17 AM ET (2026-11-14T09:17:26Z)

user task cap 83% used (10000 of 12000 tasks for uid aaron) - holders: app.slice/tmux-spawn-c2f9b92f(8200) app.slice/tmux-spawn-b4f3563c(760) app.slice/tmux-spawn-457529e5(240) app.slice/ak47-health(6) - past 100% every fork fails EAGAIN and the fleet stops starting; the slice cap is tasksmax-slice.conf and the per-unit cap is /etc/systemd/user.conf.d/60-ak47-tasksmax-user.conf - find the lane that grew: ~/.local/state/ak47/tasks-latest.md

samples: ~/.local/state/ak47/samples.log | findings: health-latest.md
