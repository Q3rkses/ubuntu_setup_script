#!/usr/bin/env python3
import argparse
import math

import rclpy
from rclpy.action import ActionClient
from rclpy.node import Node
from vortex_msgs.action import GuidanceWaypoint
from vortex_msgs.msg import WaypointMode


def euler_to_quaternion(roll, pitch, yaw):
    """ZYX convention (Fossen), angles in radians."""
    cr, sr = math.cos(roll / 2), math.sin(roll / 2)
    cp, sp = math.cos(pitch / 2), math.sin(pitch / 2)
    cy, sy = math.cos(yaw / 2), math.sin(yaw / 2)

    qw = cr * cp * cy + sr * sp * sy
    qx = sr * cp * cy - cr * sp * sy
    qy = cr * sp * cy + sr * cp * sy
    qz = cr * cp * sy - sr * sp * cy
    return qw, qx, qy, qz


class WaypointSender(Node):
    def __init__(self):
        super().__init__('waypoint_sender')
        self._client = ActionClient(
            self, GuidanceWaypoint, '/nautilus/reference_filter'
        )

    def send_goal(self, x, y, z, roll_deg, pitch_deg, yaw_deg,
                  mode=WaypointMode.FULL_POSE, threshold=0.1):
        self.get_logger().info('Waiting for action server...')
        deadline = self.get_clock().now().nanoseconds + int(5e9)
        while not self._client.server_is_ready():
            if self.get_clock().now().nanoseconds > deadline:
                self.get_logger().error(
                    'Action server /nautilus/reference_filter not found. '
                    'Is the sim running with --controller_type adapt_quat?'
                )
                return False
            rclpy.spin_once(self, timeout_sec=0.1)

        goal = GuidanceWaypoint.Goal()

        roll = math.radians(roll_deg)
        pitch = math.radians(pitch_deg)
        yaw = math.radians(yaw_deg)
        qw, qx, qy, qz = euler_to_quaternion(roll, pitch, yaw)

        goal.waypoint.pose.position.x = x
        goal.waypoint.pose.position.y = y
        goal.waypoint.pose.position.z = z
        goal.waypoint.pose.orientation.w = qw
        goal.waypoint.pose.orientation.x = qx
        goal.waypoint.pose.orientation.y = qy
        goal.waypoint.pose.orientation.z = qz
        goal.waypoint.waypoint_mode.mode = mode
        goal.convergence_threshold = threshold

        self.get_logger().info(
            f'Sending: pos=({x}, {y}, {z}), '
            f'rpy=({roll_deg:.1f}, {pitch_deg:.1f}, {yaw_deg:.1f}) deg, '
            f'mode={mode}, threshold={threshold}'
        )

        future = self._client.send_goal_async(
            goal, feedback_callback=self.feedback_cb
        )
        rclpy.spin_until_future_complete(self, future)

        goal_handle = future.result()
        if not goal_handle.accepted:
            self.get_logger().error('Goal rejected!')
            return False

        self.get_logger().info('Goal accepted, waiting for result...')
        result_future = goal_handle.get_result_async()
        rclpy.spin_until_future_complete(self, result_future)

        result = result_future.result().result
        self.get_logger().info(f'Success: {result.success}')
        return result.success

    def feedback_cb(self, feedback_msg):
        ref = feedback_msg.feedback.reference
        self.get_logger().info(
            f'  ref: pos=({ref.x:.2f}, {ref.y:.2f}, {ref.z:.2f}) '
            f'rpy=({math.degrees(ref.roll):.1f}, {math.degrees(ref.pitch):.1f}, {math.degrees(ref.yaw):.1f}) deg'
        )


def parse_args():
    parser = argparse.ArgumentParser(
        description='Send a waypoint to the quat DP reference filter.'
    )
    parser.add_argument('x', type=float, help='X position [m]')
    parser.add_argument('y', type=float, help='Y position [m]')
    parser.add_argument('z', type=float, help='Z position [m]')
    parser.add_argument('roll', type=float, nargs='?', default=0.0, help='Roll [deg] (default: 0)')
    parser.add_argument('pitch', type=float, nargs='?', default=0.0, help='Pitch [deg] (default: 0)')
    parser.add_argument('yaw', type=float, nargs='?', default=0.0, help='Yaw [deg] (default: 0)')
    parser.add_argument('--threshold', type=float, default=0.1, help='Convergence threshold (default: 0.1)')
    parser.add_argument(
        '--mode', type=int, default=WaypointMode.FULL_POSE,
        choices=[WaypointMode.FULL_POSE, WaypointMode.ONLY_POSITION,
                 WaypointMode.FORWARD_HEADING, WaypointMode.ONLY_ORIENTATION],
        help='Waypoint mode: 0=FULL_POSE, 1=ONLY_POSITION, 2=FORWARD_HEADING, 3=ONLY_ORIENTATION (default: 0)'
    )
    return parser.parse_args()


def main():
    args = parse_args()
    rclpy.init()
    sender = WaypointSender()

    sender.send_goal(
        args.x, args.y, args.z,
        args.roll, args.pitch, args.yaw,
        mode=args.mode,
        threshold=args.threshold,
    )

    sender.destroy_node()
    rclpy.shutdown()


if __name__ == '__main__':
    main()
