# ak47 health 4:17 AM ET (2026-11-14T09:17:26Z)
load 25.50 / 20.45 / 18.83 on 32 threads | RAM 87/123 GB free | swap 98% | pressure cpu 10.42 mem-full 0.06 io-full 2.96
disk 32% | /tmp 1 GB | inotify 0/8192 | CPU °C NVMe °C | net enp97s0 MHz dBm Mbit | agents 0 | watcher 1794647846s

## findings
- Swap is 98% full; 87 GB RAM is free, so 'sudo swapoff -a && sudo swapon -a' would safely reclaim it
- PAGE! user task cap 83% used (10000 of 12000 tasks for uid aaron) - holders: app.slice/tmux-spawn-c2f9b92f(8200) app.slice/tmux-spawn-b4f3563c(760) app.slice/tmux-spawn-457529e5(240) app.slice/ak47-health(6) - past 100% every fork fails EAGAIN and the fleet stops starting; the slice cap is tasksmax-slice.conf and the per-unit cap is /etc/systemd/user.conf.d/60-ak47-tasksmax-user.conf - find the lane that grew: ~/.local/state/ak47/tasks-latest.md
- no /tmp/evrun/home/.local/state/ak47/devops.log: the ak47 hygiene tick has never run on this box

## automatic fixes this run
none
