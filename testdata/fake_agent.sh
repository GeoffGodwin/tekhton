#!/usr/bin/env bash
# =============================================================================
# testdata/fake_agent.sh — configurable fake agent for supervisor integration
# tests.
#
# The supervisor (m06) launches the agent binary via exec.CommandContext and
# scans stdout for streaming JSON events. This fixture stands in for the real
# `claude` CLI under test: it ignores its argv and instead reads three env
# vars to script its behavior:
#
#   FAKE_AGENT_MODE     — one of:
#                          happy           (default) emit two turns + exit 0
#                          fail            emit one turn + exit FAKE_AGENT_EXIT
#                          slow            sleep FAKE_AGENT_SLEEP between lines
#                          flood           emit FAKE_AGENT_LINES turns then exit
#                          mixed           emit one valid line, one malformed
#                          stderr_chatter  emit N stderr lines then succeed
#                          long_line       emit a single line of LARGE size
#                          hang            emit one turn + sleep forever (tests caller-driven/timer-driven cancel)
#                          silent_fs_writer  emit startup line, write files periodically, no further stdout
#                          silent_no_writes  emit startup line then sleep without fs activity
#   FAKE_AGENT_LINES         — line count for mode=flood (default 100)
#   FAKE_AGENT_SLEEP         — seconds between lines for mode=slow (default 1)
#   FAKE_AGENT_EXIT          — exit code for mode=fail (default 1)
#   FAKE_AGENT_LARGE         — bytes for mode=long_line (default 200000)
#   FAKE_AGENT_WORKDIR       — working dir for file writes in mode=silent_fs_writer (default .)
#   FAKE_AGENT_FS_INTERVAL   — seconds between file writes (default 0.5)
#   FAKE_AGENT_FS_COUNT      — number of file writes (default 4)
#
# All output is line-buffered so the supervisor's bufio.Scanner sees lines
# as they are emitted; printf with explicit \n is enough on macOS/Linux.
# =============================================================================

set -u

mode="${FAKE_AGENT_MODE:-happy}"
lines="${FAKE_AGENT_LINES:-100}"
sleep_secs="${FAKE_AGENT_SLEEP:-1}"
exit_code="${FAKE_AGENT_EXIT:-1}"
large="${FAKE_AGENT_LARGE:-200000}"

emit() {
    printf '%s\n' "$1"
}

case "$mode" in
    happy)
        emit '{"type":"turn_started","turn":1}'
        emit '{"type":"turn_ended","turn":1}'
        emit '{"type":"turn_started","turn":2}'
        emit '{"type":"turn_ended","turn":2}'
        exit 0
        ;;
    fail)
        emit '{"type":"turn_started","turn":1}'
        emit '{"type":"error","detail":"forced failure"}'
        exit "$exit_code"
        ;;
    slow)
        emit '{"type":"turn_started","turn":1}'
        sleep "$sleep_secs"
        emit '{"type":"turn_ended","turn":1}'
        exit 0
        ;;
    flood)
        # Each iteration emits one event; turn count == iteration so the
        # supervisor can read TurnsUsed directly off the highest turn seen.
        i=1
        while [ "$i" -le "$lines" ]; do
            emit "{\"type\":\"turn_ended\",\"turn\":${i}}"
            i=$((i + 1))
        done
        exit 0
        ;;
    mixed)
        emit '{"type":"turn_started","turn":1}'
        emit 'this is not json'
        emit '{"type":"turn_ended","turn":1}'
        exit 0
        ;;
    stderr_chatter)
        # Emits lines 1..N on stderr, one stdout line, then exits.
        i=1
        n="$lines"
        while [ "$i" -le "$n" ]; do
            printf 'stderr line %d\n' "$i" 1>&2
            i=$((i + 1))
        done
        emit '{"type":"turn_ended","turn":1}'
        exit 0
        ;;
    long_line)
        # Emit a single JSON line whose `detail` field is `large` bytes long.
        # This exercises bufio.Scanner's grown buffer.
        payload=$(head -c "$large" /dev/zero | tr '\0' 'a')
        emit "{\"type\":\"tool_use\",\"turn\":1,\"detail\":\"${payload}\"}"
        exit 0
        ;;
    hang)
        # Emits one line, then sleeps forever. Exercises caller-driven and
        # activity-timer-driven cancellation paths.
        emit '{"type":"turn_started","turn":1}'
        # Use a long sleep that's still trivially killed by SIGTERM/SIGKILL.
        sleep 600
        exit 0
        ;;
    silent_fs_writer)
        # Emits a single startup line on stdout (so the supervisor knows the
        # agent is alive at all), then writes one file every FAKE_AGENT_FS_INTERVAL
        # seconds for FAKE_AGENT_FS_COUNT iterations without any further stdout.
        # Targets m09 fsnotify-driven activity-timer override: the supervisor
        # should observe filesystem activity and reset the timer instead of
        # killing the agent. The write happens BEFORE the sleep on each
        # iteration so the watcher sees recent activity prior to each timer
        # fire.
        emit '{"type":"turn_started","turn":1}'
        workdir="${FAKE_AGENT_WORKDIR:-.}"
        interval="${FAKE_AGENT_FS_INTERVAL:-0.5}"
        count="${FAKE_AGENT_FS_COUNT:-4}"
        i=1
        while [ "$i" -le "$count" ]; do
            printf 'iter %d\n' "$i" > "${workdir}/silent_${i}.txt"
            sleep "$interval"
            i=$((i + 1))
        done
        emit '{"type":"turn_ended","turn":1}'
        exit 0
        ;;
    silent_no_writes)
        # Emits a single startup line then sleeps without any stdout or
        # filesystem activity. The activity timer should fire normally
        # (m09 override path checks fsnotify; no activity → kill).
        emit '{"type":"turn_started","turn":1}'
        sleep "${FAKE_AGENT_SLEEP:-30}"
        exit 0
        ;;
    *)
        printf 'fake_agent: unknown mode %q\n' "$mode" 1>&2
        exit 64
        ;;
esac
