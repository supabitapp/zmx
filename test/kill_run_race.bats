#!/usr/bin/env bats
# Regression tests for the `zmx kill X; zmx run X` race.
#
# Previously `zmx kill` returned immediately after sending the IPC .Kill,
# while the daemon's shutdown defer ran handleKill() -- SIGHUP, 500ms sleep,
# SIGKILL -- BEFORE closing/unlinking the listen socket. A `zmx run X`
# issued in that window would connect() into the kernel backlog of a
# socket the daemon would never accept() on again, then get RST'd
# (ConnectionResetByPeer) when the daemon finally closed the listen fd,
# exiting 1 with no output and no session created.
#
# The daemon now unlinks its socket last, after reaping the pty child, so a
# replacement session can be up and serving while the old daemon is still
# working through that grace sleep.

load test_helper

@test "kill then immediate run with same name succeeds" {
  for i in 1 2 3; do
    "$ZMX" run race-x -d echo first
    wait_for_session race-x

    "$ZMX" kill race-x

    # Immediately reuse the same session name. Must not land in the
    # dying daemon's listen backlog.
    run "$ZMX" run race-x -d echo second
    echo "iteration $i: status=$status output=$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"session \"race-x\" created"* ]]

    # New session must be live and serving requests.
    wait_for_session race-x
    run "$ZMX" history race-x
    [ "$status" -eq 0 ]

    "$ZMX" kill race-x
  done
}

@test "replacement session survives the dying daemon's shutdown" {
  "$ZMX" run race-y -d echo first
  wait_for_session race-y

  "$ZMX" kill race-y
  run "$ZMX" run race-y -d echo second
  [ "$status" -eq 0 ]
  wait_for_session race-y

  # Outlast handleKill's 500ms SIGHUP->SIGKILL grace sleep. The old daemon
  # unlinks its socket after that; it must leave the replacement's file alone.
  sleep 1.5

  run "$ZMX" list --short
  [[ "$output" == *"race-y"* ]]
  run "$ZMX" history race-y
  [ "$status" -eq 0 ]

  "$ZMX" kill race-y
}
