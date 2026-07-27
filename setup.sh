#!/usr/bin/env bash
#
# ETW III — Pi setup (Layer 2)
#
# Run on the robot's own Raspberry Pi, after Layer 1 (hostname, user
# account, SSH, and hotspot WiFi, set via Raspberry Pi Imager's OS
# customisation screen during flashing — see cloud-init/README.md) has
# already applied.
#
#   git clone https://github.com/<org>/etw3-setup && cd etw3-setup
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
LIBCAMERA_PREFIX=/opt/etw3-libcamera
CAMERA_ENV_FILE="$RUN_HOME/.etw3_camera_env"
STAGE_NAME="(not started)"

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
    echo "!! Created team.env from team.env.example — this repo doesn't know"
    echo "!! your team's config yet. Edit team.env now:"
    echo "!!   - TEAM_REPO_URL   (leave blank if your team repo doesn't exist yet)"
    echo "!!   - LIBCAMERA_PKG_URL"
    echo "!!   - CAMERA_ROS_REPO"
    echo "!! Then re-run ./setup.sh."
    exit 1
fi
# shellcheck disable=SC1090
source "$ENV_CONFIG"
: "${LIBCAMERA_PKG_URL:?Set LIBCAMERA_PKG_URL in team.env}"
: "${CAMERA_ROS_REPO:?Set CAMERA_ROS_REPO in team.env}"
TEAM_REPO_URL="${TEAM_REPO_URL:-}"

# ---------------------------------------------------------------------------
stage "Stage 1/7: apt update/upgrade"

sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

# ---------------------------------------------------------------------------
stage "Stage 2/7: 2 GB swap (mandatory on 2 GB RAM)"

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
grep -q "^dtparam=i2c_arm=on" "$CONFIG_TXT" || echo "dtparam=i2c_arm=on" | sudo tee -a "$CONFIG_TXT" >/dev/null
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
stage "Stage 5/7: prebuilt libcamera + camera_ros + LD_LIBRARY_PATH workaround"
# NOTE (instructor, before S1): build and host the prebuilt libcamera
# package referenced by LIBCAMERA_PKG_URL — see etw3-setup/libcamera/README.md.
# Students never compile libcamera on the Pi.

if [ ! -d "$LIBCAMERA_PREFIX" ]; then
    curl -fsSL -o /tmp/etw3-libcamera.tar.gz "$LIBCAMERA_PKG_URL"
    sudo mkdir -p "$LIBCAMERA_PREFIX"
    sudo tar -xzf /tmp/etw3-libcamera.tar.gz -C "$LIBCAMERA_PREFIX"
    echo "Installed prebuilt libcamera to $LIBCAMERA_PREFIX."
else
    echo "$LIBCAMERA_PREFIX already present, skipping download."
fi

cat > "$CAMERA_ENV_FILE" <<EOF
# Sourced from ~/.bashrc. Session-only on purpose — this points at our
# custom libcamera build, not the system one. See the S4 camera handout
# for why this can't be a system-wide ld.so.conf entry.
export LD_LIBRARY_PATH="$LIBCAMERA_PREFIX/lib:\$LD_LIBRARY_PATH"
export PKG_CONFIG_PATH="$LIBCAMERA_PREFIX/lib/pkgconfig:\$PKG_CONFIG_PATH"
EOF
grep -q "source $CAMERA_ENV_FILE" "$RUN_HOME/.bashrc" || \
    echo "source $CAMERA_ENV_FILE" >> "$RUN_HOME/.bashrc"

mkdir -p "$WORKSPACE_DIR/src"
if [ ! -d "$WORKSPACE_DIR/src/camera_ros" ]; then
    git clone "$CAMERA_ROS_REPO" "$WORKSPACE_DIR/src/camera_ros"
else
    echo "camera_ros already cloned, skipping."
fi

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
echo "Log out and back in (or run: newgrp video) so group membership takes"
echo "effect, then run ./verify.sh."
