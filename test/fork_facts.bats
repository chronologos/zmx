#!/usr/bin/env bats
# Fork: the daemon's facts file (src/fork/FACTS.md). The record rules are unit-tested in
# src/fork/facts.zig; these cover what only a real daemon can show.

load test_helper

facts() { echo "$ZMX_DIR.facts/now/$1"; }

wait_for_fact() {
  local name="$1" pattern="$2" timeout="${3:-5}" i=0
  while (( i < timeout * 10 )); do
    if grep -qE "$pattern" "$(facts "$name")" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
    (( i++ )) || true
  done
  echo "Timed out waiting for '$pattern' in:" >&2
  cat "$(facts "$name")" >&2 || true
  return 1
}

mode_of() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"; }

@test "facts: a report from a detached session lands in the file" {
  cat > "$BATS_TEST_TMPDIR/agent.sh" <<'EOF'
printf '\033]7501;state=sideways:id=bad\033\\'
printf '\033]7501;state=working:app=demo:progress=40\033\\'
printf '\033]9;4;1;40\033\\'
sleep 30
EOF
  "$ZMX" run test-facts -d bash "$BATS_TEST_TMPDIR/agent.sh"
  wait_for_fact test-facts '^status [0-9]+ [0-9]+ state=working:app=demo:progress=40$'
  wait_for_fact test-facts '^progress [0-9]+ [0-9]+ set 40$'
  run head -1 "$(facts test-facts)"
  [[ "$output" =~ ^v=1\ pid=[0-9]+\ born=[0-9]+\ seq=[0-9]+$ ]]
  run grep -c sideways "$(facts test-facts)"
  [ "$output" -eq 0 ]
}

@test "facts: the probe is answered before device attributes, nobody attached" {
  # Both replies contain a 'c', so reading up to the first one tells which came first.
  cat > "$BATS_TEST_TMPDIR/probe.sh" <<EOF
stty -echo -icanon min 1 time 0
printf '\\033]7501;?\\033\\\\\\033[c'
IFS= read -r -t 3 -d c first
printf '%s' "\$first" | tr -d '\\033' > "$BATS_TEST_TMPDIR/first"
sleep 30
EOF
  "$ZMX" run test-probe -d bash "$BATS_TEST_TMPDIR/probe.sh"
  local i=0
  while [[ ! -s "$BATS_TEST_TMPDIR/first" ]] && (( i < 50 )); do sleep 0.1; (( i++ )) || true; done
  run cat "$BATS_TEST_TMPDIR/first"
  [[ "$output" == "]7501;?:states="* ]]
}

@test "facts: zmx print can set a status too" {
  "$ZMX" run test-print -d sleep 30
  wait_for_session test-print
  printf '\033]7501;state=done:app=hook\033\\' | "$ZMX" print test-print
  wait_for_fact test-print 'state=done:app=hook$'
}

@test "facts: directories and files are private" {
  "$ZMX" run test-private -d sleep 30
  wait_for_fact test-private '^v=1 '
  [ "$(mode_of "$ZMX_DIR.facts")" = 700 ]
  [ "$(mode_of "$ZMX_DIR.facts/now")" = 700 ]
  [ "$(mode_of "$ZMX_DIR.facts/tmp")" = 700 ]
  [ "$(mode_of "$(facts test-private)")" = 600 ]
  [ -z "$(ls -A "$ZMX_DIR.facts/tmp")" ]
}

@test "facts: a symlink in place of the directory is refused, the session still works" {
  mkdir "$BATS_TEST_TMPDIR/elsewhere"
  ln -s "$BATS_TEST_TMPDIR/elsewhere" "$ZMX_DIR.facts"
  "$ZMX" run test-symlink -d sleep 30
  wait_for_session test-symlink
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/elsewhere")" ]
}
