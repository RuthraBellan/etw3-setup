#!/usr/bin/env bash
#
# ETW III — Pi setup (Layer 2)
#
# Run on the robot's own Raspberry Pi, after Layer 1 (hostname, user
# account, SSH, and hotspot WiFi, set via Raspberry Pi Imager's OS
# customisation screen during flashing — see cloud-init/README.md) has
# already applied.
#
#   git clone https://github.com/RuthraBellan/etw3-setup && cd etw3-setup
#   ./setup.sh
#
# Safe to re-run: every stage checks whether it already did its job before
# doing anything. If your SSH session drops halfway through, just run
# ./setup.sh again — finished stages skip in seconds, the interrupted one
# picks back up.

set -euo pipefail

RUN_USER="${SUDO_USER:-$USER}"
RUN_HOME="$(getent passwd "$RUN_USER" | cut -d: -f6)"
WORKSPACE_DIR="$RUN_HOME/etw3_ws"
BUILD_DIR="$RUN_HOME/etw3-build"
LIBCAMERA_LIBDIR="/usr/local/lib/aarch64-linux-gnu"
CAMERA_ENV_FILE="$RUN_HOME/.etw3_camera_env"
STAGE_NAME="(not started)"
REBOOT_NEEDED=0

# Pinned to the exact commits validated on real Pi 4 + Ubuntu 24.04
# hardware on 2026-07-27 (see pi-camera-ov5647-setup-steps.md). Bump these
# deliberately, not casually — this combination is what's actually tested.
LIBCAMERA_COMMIT="06c385619acb10bbfb33f52f3abeb8f8c095f42b"
RPICAM_APPS_COMMIT="d34adeb63c7eb4117efca8d4ed7969dd1b6492b5"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_CONFIG="$SCRIPT_DIR/team.env"
ENV_EXAMPLE="$SCRIPT_DIR/team.env.example"

trap 'echo; echo "!! setup.sh failed during: ${STAGE_NAME}"; echo "!! Fix the issue above, then just re-run ./setup.sh — finished stages will skip."; exit 1' ERR

stage() {
    STAGE_NAME="$1"
    echo
    echo "==> ${STAGE_NAME}"
}

# ---------------------------------------------------------------------------
stage "Stage 0/7: sanity checks + team config"

TEAM_NN="$(hostname -s | sed -nE 's/^etw3-bot-([0-9]+)$/\1/p')"
if [ -z "$TEAM_NN" ]; then
    echo "!! Hostname is '$(hostname -s)', expected etw3-bot-NN."
    echo "!! Did you set the hostname to etw3-bot-NN in Raspberry Pi Imager's"
    echo "!! OS customisation screen during flashing, using your team's card?"
    echo "!! (Settings > General > Set hostname)"
    exit 1
fi
echo "Team number: $TEAM_NN"

if [ ! -f "$ENV_CONFIG" ]; then
    cp "$ENV_EXAMPLE" "$ENV_CONFIG"
    echo "Created team.env from team.env.example (TEAM_REPO_URL is blank —"
    echo "that's fine before S2; edit team.env and re-run once your team repo exists)."
fi
# shellcheck disable=SC1090
source "$ENV_CONFIG"
TEAM_REPO_URL="${TEAM_REPO_URL:-}"

# ---------------------------------------------------------------------------
stage "Stage 1/7: 2 GB swap (mandatory on 2 GB RAM)"
# Runs before the first apt upgrade: a swapless 2 GB Pi can OOM/thrash during
# a big first-boot upgrade (kernel, systemd, etc.), which can hang the whole
# box hard enough to drop off the network entirely.

SWAPFILE=/swapfile
if [ ! -f "$SWAPFILE" ]; then
    sudo fallocate -l 2G "$SWAPFILE"
    sudo chmod 600 "$SWAPFILE"
    sudo mkswap "$SWAPFILE"
    sudo swapon "$SWAPFILE"
    grep -q "^$SWAPFILE " /etc/fstab || echo "$SWAPFILE none swap sw 0 0" | sudo tee -a /etc/fstab >/dev/null
    echo "Created and enabled $SWAPFILE (2G)."
else
    sudo swapon "$SWAPFILE" 2>/dev/null || true
    echo "$SWAPFILE already exists, left as is."
fi

# ---------------------------------------------------------------------------
stage "Stage 2/7: apt update/upgrade"

sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

if [ -f /var/run/reboot-required ]; then
    echo "!! This upgrade needs a reboot (likely a kernel update) before we build"
    echo "!! kernel-adjacent components (libcamera) in stage 5 — building against"
    echo "!! a stale running kernel can misbehave."
    echo "!! Run: sudo reboot"
    echo "!! Then SSH back in and run ./setup.sh again — everything above this"
    echo "!! point will skip."
    exit 1
fi

# ---------------------------------------------------------------------------
stage "Stage 3/7: ROS 2 Jazzy base + colcon + rosdep"
# NOTE (instructor, before S1): verify this install method against
# https://docs.ros.org/en/jazzy/Installation/Ubuntu-Install-Debs.html
# — the ros-apt-source package/version scheme has changed before.

if ! dpkg -s ros-jazzy-ros-base >/dev/null 2>&1; then
    sudo apt-get install -y software-properties-common curl gnupg
    sudo add-apt-repository -y universe
    sudo apt-get update

    ROS_APT_SOURCE_VERSION="$(curl -fsSL https://api.github.com/repos/ros-infrastructure/ros-apt-source/releases/latest \
        | grep -F '"tag_name"' | head -n1 | awk -F'"' '{print $4}')"
    CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
    curl -fsSL -o /tmp/ros2-apt-source.deb \
        "https://github.com/ros-infrastructure/ros-apt-source/releases/download/${ROS_APT_SOURCE_VERSION}/ros2-apt-source_${ROS_APT_SOURCE_VERSION}.${CODENAME}_all.deb"
    sudo apt-get install -y /tmp/ros2-apt-source.deb

    sudo apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
    sudo apt-get install -y ros-jazzy-ros-base python3-colcon-common-extensions python3-rosdep

    sudo rosdep init || true   # already-initialized is fine, not an error
    rosdep update
else
    echo "ros-jazzy-ros-base already installed."
fi

grep -q "source /opt/ros/jazzy/setup.bash" "$RUN_HOME/.bashrc" || \
    echo "source /opt/ros/jazzy/setup.bash" >> "$RUN_HOME/.bashrc"

# ---------------------------------------------------------------------------
stage "Stage 4/7: OpenCV/numpy + Freenove I2C/GPIO libs + enable I2C"
# Freenove 4WD Smart Car Kit for Raspberry Pi (FNK0043):
# https://github.com/Freenove/Freenove_4WD_Smart_Car_Kit_for_Raspberry_Pi
# We vendor just the four hardware-driver modules (motor, PCA9685,
# ultrasonic, servo) pinned to a fixed commit, wrapped as an ament_python
# package so ROS 2 nodes can `import freenove_driver.motor` etc. See
# freenove-driver-pkg/freenove_driver/NOTICE.md (copied alongside) for
# license (CC BY-NC-SA 3.0) and exactly what was changed from the original.

sudo apt-get install -y python3-opencv python3-numpy python3-pip i2c-tools python3-smbus python3-gpiozero
python3 -m pip install --break-system-packages --upgrade rpi-lgpio   # gpiozero's GPIO backend on Ubuntu (Pi 4)

CONFIG_TXT=/boot/firmware/config.txt
if ! grep -q "^dtparam=i2c_arm=on" "$CONFIG_TXT"; then
    echo "dtparam=i2c_arm=on" | sudo tee -a "$CONFIG_TXT" >/dev/null
    REBOOT_NEEDED=1
fi
grep -q "^i2c-dev" /etc/modules || echo "i2c-dev" | sudo tee -a /etc/modules >/dev/null
sudo modprobe i2c-dev || true

FREENOVE_PKG_DIR="$WORKSPACE_DIR/src/freenove_driver"
FREENOVE_COMMIT="a49db4b9dfa9b7a82d172354cb3b4e0ed64985e5"
FREENOVE_RAW_BASE="https://raw.githubusercontent.com/Freenove/Freenove_4WD_Smart_Car_Kit_for_Raspberry_Pi/${FREENOVE_COMMIT}/Code/Server"

if [ ! -f "$FREENOVE_PKG_DIR/freenove_driver/motor.py" ]; then
    mkdir -p "$WORKSPACE_DIR/src"
    cp -r "$SCRIPT_DIR/freenove-driver-pkg" "$FREENOVE_PKG_DIR"
    for f in motor.py pca9685.py servo.py ultrasonic.py; do
        curl -fsSL -o "$FREENOVE_PKG_DIR/freenove_driver/$f" "$FREENOVE_RAW_BASE/$f"
    done
    # Freenove ships these as flat same-directory imports; make the two
    # that reference pca9685 relative so they work as a package (see
    # NOTICE.md for the full explanation).
    sed -i 's/^from pca9685 import PCA9685/from .pca9685 import PCA9685/' \
        "$FREENOVE_PKG_DIR/freenove_driver/motor.py" \
        "$FREENOVE_PKG_DIR/freenove_driver/servo.py"
    echo "Vendored Freenove driver modules (commit ${FREENOVE_COMMIT:0:7}) into $FREENOVE_PKG_DIR"
else
    echo "Freenove driver modules already vendored, skipping."
fi

# ---------------------------------------------------------------------------
stage "Stage 5/7: camera (libcamera + rpicam-apps, built from source; camera_ros)"
# Builds Raspberry Pi's libcamera fork + rpicam-apps from source, exactly as
# validated on real Pi 4 + Ubuntu 24.04 hardware on 2026-07-27 (see
# pi-camera-ov5647-setup-steps.md in the course-materials repo). This is a
# deliberate departure from "students never compile on the Pi": we tried a
# prebuilt-package approach first and hit enough friction producing/hosting
# it under time pressure that building live, from a pinned/validated recipe,
# turned out more reliable for S1. It costs real class time — see the S1
# run-sheet for the timing this needs to absorb.
#
# NOTE: this needs ~20-40+ min for libcamera alone on a Pi 4, plus more for
# rpicam-apps. It's also CPU-bound, so staggering start times (which helps
# the network-bound apt/ROS stages) doesn't shrink it much — every team's
# Pi is going to be busy compiling for a real chunk of the session.

mkdir -p "$BUILD_DIR"

if [ ! -f "$LIBCAMERA_LIBDIR/libcamera-base.so" ]; then
    sudo apt-get install -y git meson cmake ninja-build python3-jinja2 \
        libboost-dev libgnutls28-dev openssl libtiff-dev pybind11-dev \
        python3-yaml python3-ply libglib2.0-dev libgstreamer-plugins-base1.0-dev \
        libboost-program-options-dev libdrm-dev libexif-dev libpng-dev

    if [ ! -d "$BUILD_DIR/libcamera" ]; then
        # Shallow-fetch just the pinned commit instead of a full clone — this repo's
        # full history is large and student teams are on hotspot-grade bandwidth.
        # GitHub allows fetching an arbitrary reachable commit SHA on public repos.
        mkdir -p "$BUILD_DIR/libcamera"
        git -C "$BUILD_DIR/libcamera" init -q
        git -C "$BUILD_DIR/libcamera" remote add origin https://github.com/raspberrypi/libcamera.git
        git -C "$BUILD_DIR/libcamera" fetch --depth 1 origin "$LIBCAMERA_COMMIT"
        git -C "$BUILD_DIR/libcamera" checkout -q FETCH_HEAD
    fi
    if [ ! -d "$BUILD_DIR/libcamera/build" ]; then
        (cd "$BUILD_DIR/libcamera" && meson setup build --buildtype=release \
            -Dpipelines=rpi/vc4 -Dipas=rpi/vc4 -Dv4l2=true -Dgstreamer=enabled \
            -Dtest=false -Dlc-compliance=disabled -Dcam=disabled -Dqcam=disabled \
            -Ddocumentation=disabled -Dpycamera=enabled)
    fi
    echo "Building libcamera — this is the slow one (20-40+ min on a Pi 4)..."
    (cd "$BUILD_DIR/libcamera" && ninja -j2 -C build && sudo ninja -C build install)
    echo "libcamera built and installed (commit ${LIBCAMERA_COMMIT:0:7})."
else
    echo "libcamera already installed, skipping build."
fi

if ! command -v rpicam-hello >/dev/null 2>&1; then
    if [ ! -d "$BUILD_DIR/rpicam-apps" ]; then
        # Shallow-fetch just the pinned commit — see libcamera clone above for why.
        mkdir -p "$BUILD_DIR/rpicam-apps"
        git -C "$BUILD_DIR/rpicam-apps" init -q
        git -C "$BUILD_DIR/rpicam-apps" remote add origin https://github.com/raspberrypi/rpicam-apps.git
        git -C "$BUILD_DIR/rpicam-apps" fetch --depth 1 origin "$RPICAM_APPS_COMMIT"
        git -C "$BUILD_DIR/rpicam-apps" checkout -q FETCH_HEAD
    fi
    if [ ! -d "$BUILD_DIR/rpicam-apps/build" ]; then
        (cd "$BUILD_DIR/rpicam-apps" && meson setup build \
            -Denable_libav=disabled -Denable_drm=enabled -Denable_egl=disabled \
            -Denable_qt=disabled -Denable_opencv=disabled -Denable_tflite=disabled \
            -Denable_hailo=disabled)
    fi
    (cd "$BUILD_DIR/rpicam-apps" && ninja -j2 -C build && sudo ninja -C build install)
    sudo ldconfig
    echo "rpicam-apps built and installed (commit ${RPICAM_APPS_COMMIT:0:7})."
else
    echo "rpicam-apps already installed, skipping build."
fi

CONFIG_TXT=/boot/firmware/config.txt
if ! grep -q "^dtoverlay=ov5647" "$CONFIG_TXT"; then
    sudo sed -i 's/^camera_auto_detect=1/camera_auto_detect=0\ndtoverlay=ov5647/' "$CONFIG_TXT"
    REBOOT_NEEDED=1
    echo "Set camera_auto_detect=0 + dtoverlay=ov5647 in $CONFIG_TXT."
else
    echo "Camera overlay already configured."
fi

# ros-jazzy-camera-ros pulls in a plain/upstream ros-jazzy-libcamera as a
# dependency, which is NOT the Pi fork we just built and will crash
# (ControlInfoMap / IPA proxy errors). The env file below forces it to use
# our build instead — this is the confirmed-working workaround, not a
# permanent fix (see pi-camera-ov5647-setup-steps.md, Known Gotcha #6).
sudo apt-get install -y ros-jazzy-camera-ros

cat > "$CAMERA_ENV_FILE" <<EOF
# Sourced from ~/.bashrc. Points camera_ros at the Raspberry Pi libcamera
# fork built in setup.sh stage 5, instead of the broken generic one
# ros-jazzy-camera-ros pulls in. Session-only workaround, not permanent —
# see Known Gotcha #6 in pi-camera-ov5647-setup-steps.md.
export LD_LIBRARY_PATH="$LIBCAMERA_LIBDIR:\$LD_LIBRARY_PATH"
export LIBCAMERA_IPA_MODULE_PATH="$LIBCAMERA_LIBDIR/libcamera/ipa"
EOF
grep -q "source $CAMERA_ENV_FILE" "$RUN_HOME/.bashrc" || \
    echo "source $CAMERA_ENV_FILE" >> "$RUN_HOME/.bashrc"

# ---------------------------------------------------------------------------
stage "Stage 6/7: user groups (video, i2c, dialout)"

sudo usermod -aG video,i2c,dialout "$RUN_USER"
echo "Added $RUN_USER to video, i2c, dialout (takes effect on next login)."

# ---------------------------------------------------------------------------
stage "Stage 7/7: clone team workspace + first build"

if [ -n "$TEAM_REPO_URL" ]; then
    if [ ! -d "$WORKSPACE_DIR/src/etw3_team${TEAM_NN}" ]; then
        git clone "$TEAM_REPO_URL" "$WORKSPACE_DIR/src/etw3_team${TEAM_NN}"
    else
        echo "Team workspace already cloned, skipping."
    fi
else
    echo "TEAM_REPO_URL is empty in team.env — skipping team code clone."
    echo "(Fine before S2; edit team.env and re-run once your team repo exists.)"
fi

# shellcheck disable=SC1091
source /opt/ros/jazzy/setup.bash
# shellcheck disable=SC1090
source "$CAMERA_ENV_FILE"

cd "$WORKSPACE_DIR"
rosdep install --from-paths src --ignore-src -r -y
colcon build --symlink-install

grep -q "source $WORKSPACE_DIR/install/setup.bash" "$RUN_HOME/.bashrc" || \
    echo "source $WORKSPACE_DIR/install/setup.bash" >> "$RUN_HOME/.bashrc"

# ---------------------------------------------------------------------------
echo
echo "==> setup.sh finished for team $TEAM_NN."
if [ "$REBOOT_NEEDED" -eq 1 ]; then
    echo "A reboot is required (I2C and/or camera device-tree changes need it"
    echo "to take effect): run 'sudo reboot', SSH back in once it's up, then"
    echo "run ./verify.sh directly — no need to re-run ./setup.sh."
else
    echo "Log out and back in (or run: newgrp video) so group membership takes"
    echo "effect, then run ./verify.sh."
fi
