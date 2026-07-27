#!/usr/bin/env python3
"""ETW III verify.sh helper: brief motor twitch test.

Uses the vendored Freenove driver (freenove_driver.motor — see
../freenove-driver-pkg/freenove_driver/NOTICE.md). Spins all four wheels
at low duty for a fraction of a second so a human watching the robot can
confirm it, then stops.

There are no wheel encoders on this kit, so PASS here only means "the
PCA9685 call over I2C didn't error" — it is not proof the wheels actually
turned. verify.sh asks the person running it to confirm visually before
recording the final result; that confirmation is the real check.

Exit codes: 0 = driver call succeeded, 1 = driver call failed,
2 = freenove_driver not importable yet (workspace not built/sourced).
"""
import sys
import time

TWITCH_DUTY = 1000    # low but enough to visibly turn the wheels (max 4095)
TWITCH_SECONDS = 0.3


def main() -> int:
    try:
        from freenove_driver.motor import Ordinary_Car
    except ImportError as e:
        print(f"check_motor: freenove_driver not importable ({e})", file=sys.stderr)
        print("check_motor: did setup.sh stage 4/7 run and the workspace build?", file=sys.stderr)
        return 2

    car = Ordinary_Car()
    try:
        car.set_motor_model(TWITCH_DUTY, TWITCH_DUTY, TWITCH_DUTY, TWITCH_DUTY)
        time.sleep(TWITCH_SECONDS)
    except Exception as e:
        print(f"check_motor: driver call failed: {e}", file=sys.stderr)
        return 1
    finally:
        car.close()

    print("check_motor: sent twitch command to all four wheels")
    return 0


if __name__ == "__main__":
    sys.exit(main())
