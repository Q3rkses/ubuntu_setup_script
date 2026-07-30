#!/bin/bash
# Launch drone simulation stack in a tmux session
# Usage: ./launch_drone_sim.sh [--ori_type quat|euler] [--controller_type pid|adapt|adapt_quat]

SESSION="drone_launch"
S="source ~/code/ros2_ws/install/setup.bash"

# =============================================
# Parse arguments
# =============================================
ORI_TYPE="euler"
CONTROLLER_TYPE="adapt"

while [[ $# -gt 0 ]]; do
  case "$1" in
  --ori_type | -o)
    ORI_TYPE="$2"
    shift 2
    ;;
  --controller_type | -c)
    CONTROLLER_TYPE="$2"
    shift 2
    ;;
  *)
    echo "Unknown argument: $1"
    echo "Usage: $0 [--ori_type quat|euler] [--controller_type pid|adapt|adapt_quat]"
    exit 1
    ;;
  esac
done

# Validate
if [[ "$ORI_TYPE" != "quat" && "$ORI_TYPE" != "euler" ]]; then
  echo "Error: ori_type must be 'quat' or 'euler' (got: $ORI_TYPE)"
  exit 1
fi

if [[ "$CONTROLLER_TYPE" != "pid" && "$CONTROLLER_TYPE" != "adapt" && "$CONTROLLER_TYPE" != "adapt_quat" ]]; then
  echo "Error: controller_type must be 'pid', 'adapt', or 'adapt_quat' (got: $CONTROLLER_TYPE)"
  exit 1
fi

# Cross-validate orientation type vs controller
if [[ "$CONTROLLER_TYPE" == "pid" && "$ORI_TYPE" != "quat" ]]; then
  echo "Warning: pid controller uses quaternion representation, consider --ori_type quat"
fi
if [[ "$CONTROLLER_TYPE" == "adapt" && "$ORI_TYPE" != "euler" ]]; then
  echo "Warning: adaptive controller uses euler representation, consider --ori_type euler"
fi
if [[ "$CONTROLLER_TYPE" == "adapt_quat" && "$ORI_TYPE" != "quat" ]]; then
  echo "Warning: adapt_quat controller uses quaternion representation, consider --ori_type quat"
fi

# Select the DP launch file
if [[ "$CONTROLLER_TYPE" == "adapt_quat" ]]; then
  DP_LAUNCH="auv_setup dp_quat.launch.py"
elif [[ "$CONTROLLER_TYPE" == "pid" ]]; then
  DP_LAUNCH="auv_setup dp.launch.py controller_type:=pid"
else
  DP_LAUNCH="auv_setup dp.launch.py"
fi

echo "[LAUNCH] ori_type=$ORI_TYPE  controller_type=$CONTROLLER_TYPE  dp_launch=$DP_LAUNCH"

# Kill existing session if it exists
tmux kill-session -t "$SESSION" 2>/dev/null

# Launch Foxglove Studio only if not already running
if ! pgrep -f foxglove-studio &>/dev/null; then
  foxglove-studio &>/dev/null &
fi

# =============================================
# Window 1: sim (4 equal panes)
# =============================================
tmux new-session -d -s "$SESSION" -n "sim"

# Grab the initial pane ID
PANE_SIM=$(tmux list-panes -t "$SESSION:sim" -F '#{pane_id}')

# Stonefish simulation (top-left)
tmux send-keys -t "$PANE_SIM" "clear && $S && ros2 launch stonefish_sim simulation.launch.py drone:=nautilus" Enter

# Split right -> Keyboard joy (top-right)
PANE_JOY=$(tmux split-window -h -t "$PANE_SIM" -P -F '#{pane_id}')
tmux send-keys -t "$PANE_JOY" "clear && $S && ros2 launch keyboard_joy keyboard_joy_node.launch.py" Enter

# Split sim pane down -> AUV setup (bottom-left)
PANE_DP=$(tmux split-window -v -t "$PANE_SIM" -P -F '#{pane_id}')
tmux send-keys -t "$PANE_DP" "clear && $S && ros2 launch $DP_LAUNCH" Enter

# Split joy pane down -> Drone sim (bottom-right)
PANE_DRONE=$(tmux split-window -v -t "$PANE_JOY" -P -F '#{pane_id}')
tmux send-keys -t "$PANE_DRONE" "clear && $S && ros2 launch stonefish_sim drone_sim.launch.py orientation_mode:=$ORI_TYPE" Enter

# Force equal pane sizes
tmux select-layout -t "$SESSION:sim" tiled

# =============================================
# Window 2: tools (2 panes)
# =============================================
tmux new-window -t "$SESSION" -n "tools"

PANE_FOX=$(tmux list-panes -t "$SESSION:tools" -F '#{pane_id}')
tmux send-keys -t "$PANE_FOX" "clear && $S && ros2 launch foxglove_bridge foxglove_bridge_launch.xml" Enter

# Split down -> Message publisher
PANE_MSG=$(tmux split-window -v -t "$PANE_FOX" -P -F '#{pane_id}')
tmux send-keys -t "$PANE_MSG" "clear && $S && ros2 launch vortex_utility_nodes message_publisher.launch.py" Enter

# =============================================
# Focus first window and attach
# =============================================
tmux select-window -t "$SESSION:sim"
tmux attach-session -t "$SESSION"
