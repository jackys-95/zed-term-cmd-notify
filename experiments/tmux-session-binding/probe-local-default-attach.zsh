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
  zsh probe-local-default-attach.zsh prepare
  zsh probe-local-default-attach.zsh attach RUN_DIRECTORY
  zsh probe-local-default-attach.zsh inspect RUN_DIRECTORY
  zsh probe-local-default-attach.zsh stop RUN_DIRECTORY

prepare creates a dedicated tmux server and two detached test sessions.
attach runs tmux's default attach selection and blocks until detached.
inspect reports the attached session and the context stored on both sessions.
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

  [[ -r "$run_dir/run-id" && -r "$run_dir/socket-name" ]] ||
    die "run directory is missing its state files"
  [[ -r "$run_dir/session-left" && -r "$run_dir/session-right" ]] ||
    die "run directory is missing its session names"
  [[ -r "$run_dir/context" && -r "$run_dir/baseline-left" && -r "$run_dir/baseline-right" ]] ||
    die "run directory is missing its context values"

  run_id=$(<"$run_dir/run-id")
  socket_name=$(<"$run_dir/socket-name")
  session_left=$(<"$run_dir/session-left")
  session_right=$(<"$run_dir/session-right")
  expected_context=$(<"$run_dir/context")
  baseline_left=$(<"$run_dir/baseline-left")
  baseline_right=$(<"$run_dir/baseline-right")
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
      break
    fi
    (( attempt += 1 ))
  done
  [[ -d "$run_dir" ]] || die "could not allocate a unique probe run directory"

  local session_left="zed-notify-probe-left-${run_id}"
  local session_right="zed-notify-probe-right-${run_id}"
  local context="local-probe-${run_id}"
  local baseline_left="untouched-left-${run_id}"
  local baseline_right="untouched-right-${run_id}"

  print -r -- "$run_id" > "$run_dir/run-id"
  print -r -- "$socket_name" > "$run_dir/socket-name"
  print -r -- "$session_left" > "$run_dir/session-left"
  print -r -- "$session_right" > "$run_dir/session-right"
  print -r -- "$context" > "$run_dir/context"
  print -r -- "$baseline_left" > "$run_dir/baseline-left"
  print -r -- "$baseline_right" > "$run_dir/baseline-right"

  print -r -- "Probe run: $run_dir"
  print -r -- "Starting an isolated tmux server on socket label: $socket_name"

  command tmux -L "$socket_name" -f /dev/null new-session -d -s "$session_left"
  tmux_probe set-option -s @zed_notify_probe_run "$run_id"
  tmux_probe new-session -d -s "$session_right"
  tmux_probe set-option -t "$session_left" @zed_notify_context "$baseline_left"
  tmux_probe set-option -t "$session_right" @zed_notify_context "$baseline_right"

  local hook_command
  # The hook runs in the attached session context; omitting -t avoids passing
  # an unexpanded format string as a target-session name.
  hook_command="set-option -F @zed_notify_context \"${context}\""
  tmux_probe set-hook -g client-attached "$hook_command"
  print -r -- "ready" > "$run_dir/status"

  print
  print -r -- "Prepared two detached sessions with distinct sentinel contexts."
  print -r -- "Next, run this from the eligible Zed terminal:"
  print -r -- "  zsh ${(q)script_path} attach ${(q)run_dir}"
  print -r -- "The attach command uses native default selection and will block until detached."
}

attach() {
  (( $# == 1 )) || die "attach requires a run directory"
  require_tmux
  require_eligible_terminal
  load_run "$1"
  [[ -r "$run_dir/status" && "$(<"$run_dir/status")" == ready ]] ||
    die "probe setup is incomplete"
  verify_probe_server

  print -r -- "Attaching with tmux's native default target selection."
  print -r -- "The isolated client-attached hook will publish: $expected_context"
  tmux_probe attach-session
}

inspect() {
  (( $# == 1 )) || die "inspect requires a run directory"
  require_tmux
  require_eligible_terminal
  load_run "$1"
  verify_probe_server

  local clients
  clients=$(tmux_probe list-clients -F '#{client_session}')
  local -a attached_sessions
  if [[ -n "$clients" ]]; then
    attached_sessions=("${(@f)clients}")
  else
    attached_sessions=()
  fi

  local left_context right_context
  left_context=$(tmux_probe show-options -qv -t "$session_left" @zed_notify_context)
  right_context=$(tmux_probe show-options -qv -t "$session_right" @zed_notify_context)

  print -r -- "Attached client sessions: ${#attached_sessions}"
  if (( ${#attached_sessions} > 0 )); then
    printf '  %s\n' "${attached_sessions[@]}"
  fi
  print -r -- "Session context values:"
  print -r -- "  $session_left: $left_context"
  print -r -- "  $session_right: $right_context"

  if (( ${#attached_sessions} != 1 )); then
    print -u2 -r -- "INCONCLUSIVE: inspect while exactly one probe client is attached."
    return 2
  fi

  local selected=${attached_sessions[1]}
  local selected_context other_context expected_other
  if [[ "$selected" == "$session_left" ]]; then
    selected_context=$left_context
    other_context=$right_context
    expected_other=$baseline_right
  elif [[ "$selected" == "$session_right" ]]; then
    selected_context=$right_context
    other_context=$left_context
    expected_other=$baseline_left
  else
    print -u2 -r -- "FAIL: the client is attached to an unexpected session: $selected"
    return 1
  fi

  if [[ "$selected_context" == "$expected_context" && "$other_context" == "$expected_other" ]]; then
    print -r -- "PASS: the actual selected session received the probe context; the other session is unchanged."
    return 0
  fi

  print -u2 -r -- "FAIL: the actual selected session did not receive the expected context, or the other session changed."
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
  attach)
    attach "$@"
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
