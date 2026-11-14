# ak47 PAGE 4:17 AM ET (2026-11-14T09:17:26Z)

user task cap 83% used (10000 of 12000 tasks for uid aaron) - holders: app.slice/tmux-spawn-c2f9b92f(8200) app.slice/tmux-spawn-b4f3563c(760) app.slice/tmux-spawn-457529e5(240) app.slice/ak47-health(6) - past 100% every fork fails EAGAIN and the fleet stops starting; the slice cap is tasksmax-slice.conf and the per-unit cap is /etc/systemd/user.conf.d/60-ak47-tasksmax-user.conf - find the lane that grew: ~/.local/state/ak47/tasks-latest.md

samples: ~/.local/state/ak47/samples.log | findings: health-latest.md
