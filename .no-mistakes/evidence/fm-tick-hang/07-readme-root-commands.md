# ak47 README: the commands only Aaron can run (rendered excerpt)

## The commands only Aaron can run

Everything else in this file is code the tick runs as a user unit. These five
things need root, so they are here in one block rather than scattered through the
sections that explain them. Each carries its revert.

```bash
# 1. The task cap. The slice ceiling applies at once; the per-unit default is
#    read when the user manager next starts, because restarting user@1000.service
#    would restart every unit in the slice.
u=ak47/hdevops/ansible/playbooks/templates
sudo install -D -m644 "$u/60-ak47-tasksmax-slice.conf" \
  /etc/systemd/system/user@1000.service.d/60-ak47-tasksmax-slice.conf
sudo install -D -m644 "$u/60-ak47-tasksmax-user.conf" \
  /etc/systemd/user.conf.d/60-ak47-tasksmax-user.conf
sudo systemctl daemon-reload
systemctl show -p TasksMax --value user@1000.service          # expect 24576
grep -h DefaultTasksMax /etc/systemd/user.conf.d/60-ak47-tasksmax-user.conf
# revert: sudo rm /etc/systemd/system/user@1000.service.d/60-ak47-tasksmax-slice.conf \
#           /etc/systemd/user.conf.d/60-ak47-tasksmax-user.conf && sudo systemctl daemon-reload

# 2. systemd-oomd, read fresh. The Nov-10 swap drop-in postdates the running
#    manager, so restarting oomd is what makes it re-read the slice's policy.
sudo systemctl restart systemd-oomd
oomctl | sed -n '/Monitored CGroups/,$p'
# revert: nothing to revert - a restart restores the same policy it read before

# 3. Let oomd actually SEE the slice. Without this, oomctl lists no monitored
#    cgroups at all and every oomd policy on this host is decoration. This is the
#    opt-in one: with it, oomd may kill the largest cgroup under the slice after
#    20s at 50% pressure, and that cgroup can be a worker or the chair.
sudo systemctl set-property --runtime user@1000.service MemoryPressureWatch=on
oomctl | sed -n '/Memory Pressure Monitored CGroups/,$p'      # expect the slice
# persist it: printf '[Service]\nMemoryPressureWatch=on\n' | sudo tee \
#   /etc/systemd/system/user@1000.service.d/60-ak47-oomd-mem.conf && sudo systemctl daemon-reload
# revert: sudo systemctl set-property --runtime user@1000.service MemoryPressureWatch=skip \
#         && sudo rm -f /etc/systemd/system/user@1000.service.d/60-ak47-oomd-mem.conf \
#         && sudo systemctl daemon-reload

# 4. Let the hygiene tick reclaim swap. swapoff/swapon are root-only and the tick
#    is a user unit, so today it can only report `swap-unprivileged`.
printf 'aaron ALL=(root) NOPASSWD: /sbin/swapoff -a, /sbin/swapon -a\n' \
  | sudo tee /etc/sudoers.d/60-ak47-swap
sudo chmod 0440 /etc/sudoers.d/60-ak47-swap
sudo visudo -c                                                  # expect: parsed OK
# revert: sudo rm /etc/sudoers.d/60-ak47-swap

# 5. The two sysctls, if this box was rebuilt rather than playbooked.
sudo sysctl --system
# revert: sudo rm /etc/sysctl.d/60-ak47-{swap,inotify}.conf && sudo sysctl --system
```
