#!/bin/sh
# Stands in for Camoufox in launcher specs. The launcher's wrapper gives it
# the Juggler pipe on fd 3 (read) and fd 4 (write), with stdout folded into
# stderr. Every mode first logs its arguments. FAKE_MODE picks the behaviour:
#
# - echo (default): print the ready line, then copy every frame from fd 3 to
#   fd 4. Exits when the launcher closes the pipe.
# - record: print the ready line, then copy every frame from fd 3 to the
#   file named by FAKE_RECORD. Exits when the launcher closes the pipe.
# - silent: never print the ready line.
# - crash: log a message and exit with status 3 before the ready line.
# - stubborn: print the ready line, then ignore pipe close and SIGTERM.
# - env: print its CAMOU_* variables, sorted, then behave as echo.
echo "args: $*"
case "${FAKE_MODE:-echo}" in
  silent)
    exec sleep 30
    ;;
  crash)
    echo "fake crash: missing library"
    exit 3
    ;;
  record)
    echo "Juggler listening to the pipe"
    exec cat <&3 >"$FAKE_RECORD"
    ;;
  stubborn)
    trap '' TERM
    echo "Juggler listening to the pipe"
    while :; do sleep 0.05; done
    ;;
  env)
    env | grep '^CAMOU_' | sort
    echo "Juggler listening to the pipe"
    exec cat <&3 >&4
    ;;
  *)
    echo "Juggler listening to the pipe"
    exec cat <&3 >&4
    ;;
esac
