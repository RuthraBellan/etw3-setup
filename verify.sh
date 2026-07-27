#!/usr/bin/env bash
#
# ETW III — S1 exit checklist, run on the robot's Pi after setup.sh.
#
#   ./verify.sh
#
# Prints PASS/FAIL/SKIP for each component. This output IS the S1 exit
# checklist — the instructor/TA signs a team off once every line that
# isn't SKIP says PASS. SKIP means "not wired up yet" (see the TODOs in
# checks/), not a robot problem — don't block sign-off on it unless the
# instructor says otherwise.

set -uo pipefail

RUN_HOME="$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)"
WORKSPACE_DIR="$RUN_HOME/etw3_ws"
CAMERA_ENV_FILE="$RUN_HOME/.etw3_camera_env"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# freenove_driver (motor/ultrasonic checks below) lives in the workspace
# install space, built by setup.sh stage 4/7.
# ROS 2's setup.bash references variables (e.g. AMENT_TRACE_SETUP_FILES)
# without a default fallback, which trips `set -u`. Relax it just for sourcing.
set +u
[ -f /opt/ros/jazzy/setup.bash ] && source /opt/ros/jazzy/setup.bash
[ -f "$WORKSPACE_DIR/install/setup.bash" ] && source "$WORKSPACE_DIR/install/setup.bash"
set -u

RESULTS=()

record() {
    # record <label> <PASS|FAIL|SKIP> <detail>
    RESULTS+=("$1|$2|$3")
    printf '%-28s %s\n' "$1" "$2"
    [ -n "${3:-}" ] && printf '   %s\n' "$3"
}

echo "== ETW III verify.sh =="
echo "Hostname: $(hostname -s)"
echo

# ---------------------------------------------------------------------------
echo "-- Camera --"
if [ -f "$CAMERA_ENV_FILE" ]; then
    # References $LD_LIBRARY_PATH, which may be unset — same set -u issue as above.
    set +u
    # shellcheck disable=SC1090
    source "$CAMERA_ENV_FILE"
    set -u
fi

if command -v rpicam-hello >/dev/null 2>&1; then
    if OUT=$(timeout 10 rpicam-hello --list-cameras 2>&1) && echo "$OUT" | grep -qi "Available cameras"; then
        record "Camera" "PASS" "$(echo "$OUT" | head -n2 | tail -n1)"
    else
        record "Camera" "FAIL" "rpicam-hello --list-cameras found no camera"
    fi
else
    record "Camera" "FAIL" "rpicam-hello not found — did setup.sh stage 5 run?"
fi

# ---------------------------------------------------------------------------
echo
echo "-- Ultrasonic --"
OUT="$(python3 "$SCRIPT_DIR/checks/check_ultrasonic.py" 2>&1)"
RC=$?
if [ "$RC" -eq 0 ]; then
    record "Ultrasonic" "PASS" "$OUT"
elif [ "$RC" -eq 2 ]; then
    record "Ultrasonic" "SKIP" "freenove_driver not built/sourced yet — rerun setup.sh"
else
    record "Ultrasonic" "FAIL" "$OUT"
fi

# ---------------------------------------------------------------------------
echo
echo "-- Motor twitch --"
echo "   The wheels will spin briefly. Make sure hands, cables, and the"
echo "   edge of the table are clear."
read -r -p "   Ready to twitch the motors? [y/N] " MOTOR_READY
if [[ "$MOTOR_READY" =~ ^[Yy]$ ]]; then
    OUT="$(python3 "$SCRIPT_DIR/checks/check_motor.py" 2>&1)"
    RC=$?
    if [ "$RC" -eq 0 ]; then
        read -r -p "   Did all four wheels visibly turn? [y/N] " SAW_IT
        if [[ "$SAW_IT" =~ ^[Yy]$ ]]; then
            record "Motor twitch" "PASS" "$OUT"
        else
            record "Motor twitch" "FAIL" "driver call succeeded but wheels didn't turn — check wiring/PCA9685"
        fi
    elif [ "$RC" -eq 2 ]; then
        record "Motor twitch" "SKIP" "freenove_driver not built/sourced yet — rerun setup.sh"
    else
        record "Motor twitch" "FAIL" "$OUT"
    fi
else
    record "Motor twitch" "SKIP" "skipped by operator"
fi

# ---------------------------------------------------------------------------
echo
echo "-- Laptop-to-Pi topic visibility --"
if command -v ros2 >/dev/null 2>&1; then
    # shellcheck disable=SC1091
    source /opt/ros/jazzy/setup.bash
    ros2 run demo_nodes_py talker >/tmp/etw3-talker.log 2>&1 &
    TALKER_PID=$!
    sleep 1

    echo "   A talker is now publishing /chatter on this Pi."
    echo "   On Laptop B (joined to this team's hotspot), run:"
    echo "     source /opt/ros/jazzy/setup.bash"
    echo "     ros2 topic echo /chatter"
    echo "   You should see messages within a few seconds."
    read -r -p "   Did messages appear on Laptop B? [y/N] " ANSWER
    kill "$TALKER_PID" 2>/dev/null || true
    wait "$TALKER_PID" 2>/dev/null || true

    if [[ "$ANSWER" =~ ^[Yy]$ ]]; then
        record "Laptop-to-Pi topics" "PASS" ""
    else
        record "Laptop-to-Pi topics" "FAIL" "check hotspot connection / both machines on ROS 2 Jazzy"
    fi
else
    record "Laptop-to-Pi topics" "FAIL" "ros2 not found — did setup.sh stage 3 run?"
fi

# ---------------------------------------------------------------------------
echo
echo "== Summary =="
FAILS=0
for row in "${RESULTS[@]}"; do
    IFS='|' read -r label status _ <<< "$row"
    printf '%-28s %s\n' "$label" "$status"
    [ "$status" = "FAIL" ] && FAILS=$((FAILS + 1))
done

echo
if [ "$FAILS" -eq 0 ]; then
    echo "All checks PASS or SKIP — team $(hostname -s) is clear for S1 sign-off."
    exit 0
else
    echo "$FAILS check(s) FAILED — not ready for sign-off yet."
    exit 1
fi
