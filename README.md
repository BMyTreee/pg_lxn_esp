# pg_lxn_esp

## Setup — one command, copy and paste

```bash
./setup_lxn.sh all
```

This runs: ssh-key → deploy → tmux-install → tmux-run (full setup)

## Other commands

```bash
./setup_lxn.sh ssh-pw        # password-based SSH instead of key
./setup_lxn.sh tmux-install  # install tmux on lxn
./setup_lxn.sh tmux-run      # start listener in tmux

# attach / tail / kill
ssh lxn -t tmux attach -t listen_lxn
ssh lxn 'tmux capture-pane -p -t listen_lxn -S -50'
ssh lxn 'tmux kill-session -t listen_lxn'

# connect from client
psql "host=lxn dbname=lxn user=lxn"
```

## Config (env vars)

```bash
LXN_HOST=lxn          # SSH host alias or IP (default: lxn)
LXN_USER=pi           # SSH user (default: pi)
LXN_PG_PASSWORD=s3cret  # role password
```
