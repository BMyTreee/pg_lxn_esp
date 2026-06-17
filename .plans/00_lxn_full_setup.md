# 00 — lxN full setup (clone + ssh + pg + db + tmux)

goal: make `setup_lxn.sh` + `README.md` complete & consistent for the full lxn bootstrap.

current state: `open-pg` (pg listen) + `fix-sshd` (pw auth) + `deploy` (db) already exist.
gaps: git-clone to lxn, tmux install/run/log, `all` flow, README sync.

## tasks
- [ ] add constants: LXN_REPO_URL, LXN_REPO_DIR, TMUX_SESSION, TMUX_LISTENER_CMD, default pg log
- [ ] cmd_clone        — git clone / pull repo on lxn
- [ ] cmd_tmux_install — apt install tmux
- [ ] cmd_tmux_run     — start listener session (tail pg log by default)
- [ ] cmd_tmux_log     — capture-pane to show recent log
- [ ] cmd_tmux_attach  — attach to session
- [ ] cmd_tmux_kill    — kill session
- [ ] update `all` to: prompt + fix-sshd + deploy + tmux-install + tmux-run
- [ ] update dispatch case + usage text
- [ ] rewrite README to match actual commands + bootstrap flow
- [ ] `bash -n` syntax check
