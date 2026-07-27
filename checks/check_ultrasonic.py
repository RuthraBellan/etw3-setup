#!/usr/bin/env python3
"""ETW III verify.sh helper: one-shot ultrasonic distance reading.

Uses the vendored Freenove driver (freenove_driver.ultrasonic — see
../freenove-driver-pkg/freenove_driver/NOTICE.md), built into the team
workspace by setup.sh stage 4. Run with the workspace sourced
(verify.sh does this before calling this script).

Exit codes: 0 = distance reading looks sane, 1 = hardware/read failure,
2 = freenove_driver not importable yet (workspace not built/sourced).
"""
import sys


def main() -> int:
    try:
        from freenove_driver.ultrasonic import Ultrasonic
    except ImportError as e:
        print(f"check_ultrasonic: freenove_driver not importable ({e})", file=sys.stderr)
        print("check_ultrasonic: did setup.sh stage 4/7 run and the workspace build?", file=sys.stderr)
        return 2

    with Ultrasonic() as sensor:
        distance_cm = sensor.get_distance()

    if distance_cm is None:
        print("check_ultrasonic: sensor returned no reading", file=sys.stderr)
        return 1

    print(f"check_ultrasonic: {distance_cm:.1f} cm")
    if 2 <= distance_cm <= 400:
        return 0
    print("check_ultrasonic: reading out of sane range (2-400 cm)", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
