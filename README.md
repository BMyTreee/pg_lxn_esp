# pg_lxn_esp

One-shot PostgreSQL provisioning for the `lxn` host (the MQTT/ESP32 broker box).

## Files

| file            | where it runs | purpose                                              |
| --------------- | ------------- | ---------------------------------------------------- |
| `ssh_setup.sh`  | local         | One-time: sets up SSH key login to `lxn`             |
| `pw_ssh_setup.sh` | local       | One-time: enables password SSH login on `lxn`        |
| `deploy.sh`     | local         | SCPs the bundle to `lxn` and triggers setup over SSH |
| `setup_pg.sh`   | on `lxn`      | apt-installs PostgreSQL, creates role + db, loads schema |
| `init.sql`      | on `lxn`      | Initial schema (idempotent)                          |
| `install_tmux.sh`| local       | apt-installs tmux on `lxn` over SSH                  |
| `tmux_run.sh`   | local         | Starts/reattaches a named tmux session on `lxn`      |

## Usage

```bash
# 1. Make sure your SSH config has a `lxn` host (or export LXN_HOST=user@ip).

# 2. One-time: enable SSH login to lxn
#    a) key-based (recommended)
./ssh_setup.sh
#    b) password-based (alternative)
./pw_ssh_setup.sh

# 3. Run the deployer
./deploy.sh

# 4. Start the listener in a detached tmux session on lxn
./tmux_run.sh
```

## Configuration

All values have sane defaults; override any of them via environment variables:

```bash
LXN_HOST=lxn                       # SSH Host alias (or IP)
LXN_USER=pi                        # SSH user
LXN_KEY_ALGO=ed25519               # key type (ed25519 | rsa)
LXN_KEY_COMMENT=lxn-deploy@host    # comment embedded in the key
LXN_REMOTE_DIR=/tmp/pg_setup       # staging dir on the remote
LXN_PG_VERSION=16                  # major PG version
LXN_PG_DB=lxn                      # database name
LXN_PG_USER=lxn                    # role name
LXN_PG_PASSWORD='changeme'         # role password
```

Example:

```bash
LXN_PG_PASSWORD='s3cret' \
LXN_PG_VERSION=15 \
./deploy.sh
```

## Verified on

- Debian / Raspberry Pi OS (uses `apt` + `pg_ctlcluster`)
- Requires apt-based distro

The setup is idempotent — re-running `deploy.sh` will update the password,
re-grant privileges, and re-apply `init.sql` (which uses `IF NOT EXISTS`).

## Connect from a client

```bash
psql "host=lxn dbname=lxn user=lxn"
```

## Other helpers

```bash
# install tmux on lxn (idempotent)
./install_tmux.sh

# start a detached session running the listener (defaults)
./tmux_run.sh

# override the command / session name / cwd
LXN_TMUX_SESSION=listener LXN_TMUX_CWD=/home/pi/listen_lxn_mqtt \
LXN_TMUX_COMMAND='/home/pi/listen_lxn_mqtt/target/release/listen_lxn_mqtt' \
./tmux_run.sh

# attach to it interactively
ssh lxn -t tmux attach -t listen_lxn
```
# pg_lxn_esp
