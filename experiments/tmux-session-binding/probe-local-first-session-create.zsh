#!/bin/zsh

emulate -LR zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL

readonly script_path=${0:A}
readonly script_dir=${script_path:h}
readonly repo_root=${script_dir:h:h}
readonly runtime_root="${repo_root}/.local/tmux-session-binding"

die() {
  print -u2 -r -- "error: $*"
  exit 1
}

usage() {
  cat <<'USAGE'
Usage:
  zsh probe-local-first-session-create.zsh prepare
  zsh probe-local-first-session-create.zsh create RUN_DIRECTORY
  zsh probe-local-first-session-create.zsh inspect RUN_DIRECTORY
  zsh probe-local-first-session-create.zsh stop RUN_DIRECTORY

prepare reserves an unused socket label and writes an isolated tmux config.
create starts that socket's first server/session and attaches with new-session.
inspect reports the attached session and its stored context.
stop stops only the dedicated probe server, after confirmation, and only when
no clients are attached.
USAGE
}

require_tmux() {
  command -v tmux >/dev/null 2>&1 || die "tmux was not found in PATH"
}

require_eligible_terminal() {
  [[ -t 0 && -t 1 ]] || die "run this action from an interactive terminal"
  [[ ${ZED_TERM:-} == true ]] || die "run this from a regular Zed integrated terminal"
  [[ ${ZED_NOTIFY_DISABLED:-} != 1 ]] || die "notifications are opted out in this terminal"
  [[ -z ${TMUX:-} ]] || die "run this from a Zed terminal outside an existing tmux client"
}

require_runtime_excluded() {
  command -v git >/dev/null 2>&1 || die "git is required to check the local runtime exclusion"
  git -C "$repo_root" check-ignore -q -- .local/tmux-session-binding/probe-runtime ||
    die ".local/tmux-session-binding must be excluded from version control before preparing the probe"
}

load_run() {
  (( $# == 1 )) || die "expected one run directory"
  local requested_dir=$1
  [[ -d "$requested_dir" ]] || die "run directory does not exist: $requested_dir"

  run_dir=${requested_dir:A}
  [[ "$run_dir" == "${runtime_root:A}/"* ]] ||
    die "run directory must be under $runtime_root"

  [[ -r "$run_dir/run-id" && -r "$run_dir/socket-name" && -r "$run_dir/context" ]] ||
    die "run directory is missing its state files"
  [[ -r "$run_dir/tmux.conf" && -r "$run_dir/status" ]] ||
    die "run directory is missing its probe config or status"

  run_id=$(<"$run_dir/run-id")
  socket_name=$(<"$run_dir/socket-name")
  expected_context=$(<"$run_dir/context")
}

tmux_probe() {
  command tmux -N -L "$socket_name" "$@"
}

verify_probe_server() {
  local actual_run_id
  actual_run_id=$(tmux_probe show-options -s -qv @zed_notify_probe_run 2>/dev/null) ||
    die "the isolated probe server is not available"
  [[ "$actual_run_id" == "$run_id" ]] ||
    die "the socket does not identify this probe's server; refusing to continue"
}

prepare() {
  (( $# == 0 )) || die "prepare takes no arguments"
  require_tmux
  require_eligible_terminal
  require_runtime_excluded

  umask 077
  mkdir -p -m 700 "$runtime_root"

  local run_id=""
  local socket_name=""
  local run_dir=""
  local attempt=0
  local allocated=0
  while (( attempt < 10 )); do
    run_id="${$}-${RANDOM}-${RANDOM}"
    socket_name="zednp-${$}-${RANDOM}-${RANDOM}"
    run_dir="${runtime_root}/${run_id}"

    if [[ -e "$run_dir" ]]; then
      (( attempt += 1 ))
      continue
    fi
    if command tmux -N -L "$socket_name" list-sessions >/dev/null 2>&1; then
      (( attempt += 1 ))
      continue
    fi
    if mkdir -m 700 "$run_dir" 2>/dev/null; then
      allocated=1
      break
    fi
    (( attempt += 1 ))
  done
  [[ "$allocated" == 1 ]] || die "could not allocate a unique probe run directory"

  local context="local-probe-${run_id}"
  print -r -- "$run_id" > "$run_dir/run-id"
  print -r -- "$socket_name" > "$run_dir/socket-name"
  print -r -- "$context" > "$run_dir/context"
  {
    print -r -- "set-option -s @zed_notify_probe_run ${run_id}"
    print -r -- "set-hook -g after-new-session \"set-option -F @zed_notify_context ${context}\""
  } > "$run_dir/tmux.conf"
  print -r -- "ready" > "$run_dir/status"

  print -r -- "Probe run: $run_dir"
  print -r -- "Reserved an unused isolated socket label: $socket_name"
  print -r -- "No tmux server was started by prepare."
  print
  print -r -- "Next, run this from the eligible Zed terminal:"
  print -r -- "  zsh ${(q)script_path} create ${(q)run_dir}"
  print -r -- "The create command starts the first server/session on this socket and stays attached until detached."
}

create() {
  (( $# == 1 )) || die "create requires a run directory"
  require_tmux
  require_eligible_terminal
  load_run "$1"
  [[ "$(<"$run_dir/status")" == ready ]] ||
    die "probe setup is incomplete"

  if command tmux -N -L "$socket_name" list-sessions >/dev/null 2>&1; then
    die "a server already exists on this probe socket; refusing to create a second session"
  fi

  print -r -- "Starting the first session on the isolated probe socket with tmux new-session."
  print -r -- "The isolated after-new-session hook will publish: $expected_context"
  command tmux -L "$socket_name" -f "$run_dir/tmux.conf" new-session
}

inspect() {
  (( $# == 1 )) || die "inspect requires a run directory"
  require_tmux
  require_eligible_terminal
  load_run "$1"
  verify_probe_server

  local sessions clients
  sessions=$(tmux_probe list-sessions -F '#{session_name}')
  clients=$(tmux_probe list-clients -F '#{client_session}')

  local -a session_names attached_sessions
  if [[ -n "$sessions" ]]; then
    session_names=("${(@f)sessions}")
  else
    session_names=()
  fi
  if [[ -n "$clients" ]]; then
    attached_sessions=("${(@f)clients}")
  else
    attached_sessions=()
  fi

  print -r -- "Probe sessions: ${#session_names}"
  if (( ${#session_names} > 0 )); then
    printf '  %s\n' "${session_names[@]}"
  fi
  print -r -- "Attached client sessions: ${#attached_sessions}"
  if (( ${#attached_sessions} > 0 )); then
    printf '  %s\n' "${attached_sessions[@]}"
  fi

  if (( ${#session_names} != 1 )); then
    print -u2 -r -- "FAIL: expected exactly one session on the fresh probe socket."
    return 1
  fi
  if (( ${#attached_sessions} != 1 )); then
    print -u2 -r -- "INCONCLUSIVE: inspect while exactly one probe client is attached."
    return 2
  fi

  local session_name=${session_names[1]}
  local selected_session=${attached_sessions[1]}
  local session_context
  session_context=$(tmux_probe show-options -qv -t "$session_name" @zed_notify_context)
  print -r -- "Initial session context: $session_context"

  if [[ "$selected_session" != "$session_name" ]]; then
    print -u2 -r -- "FAIL: the attached client is not on the only probe session."
    return 1
  fi
  if [[ "$session_context" == "$expected_context" ]]; then
    print -r -- "PASS: the first created session received the probe context while attached."
    return 0
  fi

  print -u2 -r -- "FAIL: the first created session did not receive the expected context."
  return 1
}

stop() {
  (( $# == 1 )) || die "stop requires a run directory"
  require_tmux
  load_run "$1"
  verify_probe_server

  local clients
  clients=$(tmux_probe list-clients -F '#{client_name}')
  [[ -z "$clients" ]] || die "detach every probe client before stopping this isolated server"

  print -n -r -- "Stop only the isolated probe server on '$socket_name'? [y/N] "
  local answer
  read -r answer
  [[ "$answer" == y || "$answer" == Y ]] || {
    print -r -- "Cancelled."
    return 0
  }

  tmux_probe kill-server
  print -r -- "Stopped the isolated probe server. Runtime evidence remains in $run_dir."
}

(( $# > 0 )) || {
  usage
  exit 2
}

action=$1
shift

case "$action" in
  prepare)
    prepare "$@"
    ;;
  create)
    create "$@"
    ;;
  inspect)
    inspect "$@"
    ;;
  stop)
    stop "$@"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage
    die "unknown action: $action"
    ;;
esac
