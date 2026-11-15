#!/usr/bin/env bash
# Run a command on node-8 through node-1 (the vRack hop). stdin is passed to the remote bash.
# usage: ./n8.sh < script.sh
exec ssh -o BatchMode=yes -o ConnectTimeout=15 root@135.148.169.37 'ssh -o BatchMode=yes -o ConnectTimeout=10 root@10.0.0.8 bash -s'
