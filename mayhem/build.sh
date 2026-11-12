#!/usr/bin/env bash
#
# mayhem/build.sh — builds libmavconn (mavros' ROS-independent MAVLink transport + parser) three ways:
# sanitized fuzz/standalone harnesses, and the upstream gtest suite with normal flags.
# The rest of mavros is ROS 2 (ament/rclcpp/tf2) and cannot be built on the base image.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

SRC="${SRC:-/mayhem}"
cd "$SRC"

MAVLINK_VER=2026.11.11
MAVLINK_INC=/opt/toolchains/deps/mavlink-${MAVLINK_VER}/include
# common + ardupilotmega pull in minimal, uAvionix, icarous, loweheiser, cubepilot and csAirLink.
DIALECTS=(common ardupilotmega)

L="$SRC/libmavconn"
B="$SRC/build/mayhem"
GEN="$B/gen"
mkdir -p "$GEN/include/mavconn" "$GEN/src" "$B/fuzz" "$B/test" /mayhem

# 1) Generate the dialect header and helpers the way libmavconn/CMakeLists.txt does (empy).
sed -e "s|@mavlink2_DIALECTS@|$(IFS=';'; echo "${DIALECTS[*]}")|" -e 's|@IGNORE_DIALECTS@||' \
  "$L/mavlink.context.py.in" > "$GEN/mavlink.context.py"
python3 -m em --raw-errors -F "$GEN/mavlink.context.py" \
  -o "$GEN/include/mavconn/mavlink_dialect.hpp" "$L/include/mavconn/mavlink_dialect.hpp.em"
python3 -m em --raw-errors -F "$GEN/mavlink.context.py" \
  -o "$GEN/src/mavlink_helpers.cpp" "$L/src/mavlink_helpers.cpp.em"

# Message-class table for the msg_dispatch.cpp harness helper: every struct in the dialects' headers.
: > "$GEN/msg_dispatch.inc"
for d in minimal common ardupilotmega uAvionix icarous loweheiser cubepilot csAirLink; do
  grep -ho '^struct [A-Za-z0-9_]* : mavlink::Message' "$MAVLINK_INC"/mavlink/v2.0/$d/*.hpp \
    | awk -v d="$d" '{print "X(" d ", " $2 ")"}' >> "$GEN/msg_dispatch.inc"
done
[ "$(wc -l < "$GEN/msg_dispatch.inc")" -gt 200 ]

CXXSTD="-std=gnu++20"
INCS="-I$GEN -I$GEN/include -I$L/include -I$SRC/mayhem -I$MAVLINK_INC"
LIB_SRCS=("$GEN/src/mavlink_helpers.cpp" "$L/src/interface.cpp" "$L/src/serial.cpp" "$L/src/tcp.cpp" "$L/src/udp.cpp")
LIBS="-lconsole_bridge -lpthread"

compile_all() {  # compile_all <outdir> <flags...> -- sources...
  local out="$1"; shift
  local flags=()
  while [ "$1" != "--" ]; do flags+=("$1"); shift; done
  shift
  printf '%s\n' "$@" | xargs -P "$MAYHEM_JOBS" -I{} sh -c \
    '$0 "$@" -c "{}" -o "'"$out"'/$(basename "{}").o"' "$CXX" "${flags[@]}"
}

# 2) The test suite with upstream's normal flags (no sanitizers), built first.
compile_all "$B/test" $CXXSTD -O0 $COVERAGE_FLAGS $INCS -- "${LIB_SRCS[@]}" "$L/test/test_mavconn.cpp"
$CXX $COVERAGE_FLAGS "$B"/test/*.o -lgtest -lconsole_bridge -lpthread -o "$B/test/test_mavconn"

# 3) The sanitized library + harness objects (SanCov on everything fuzzed, via fuzzer-no-link).
FUZZ_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -O1 -fsanitize=fuzzer-no-link"
compile_all "$B/fuzz" $CXXSTD $FUZZ_FLAGS $INCS -- "${LIB_SRCS[@]}" "$SRC/mayhem/msg_dispatch.cpp" \
  "$SRC/mayhem/fuzz_mavconn_parse/fuzz_mavconn_parse.cpp" "$SRC/mayhem/fuzz_mavlink_msg/fuzz_mavlink_msg.cpp"
# msg_dispatch.cpp includes msg_dispatch.inc from the generated dir.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$B/fuzz-lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$B/standalone_main.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/sancov_stubs.c" -o "$B/sancov_stubs.o"

LIB_OBJS=("$B"/fuzz/mavlink_helpers.cpp.o "$B"/fuzz/interface.cpp.o "$B"/fuzz/serial.cpp.o \
  "$B"/fuzz/tcp.cpp.o "$B"/fuzz/udp.cpp.o "$B"/fuzz/msg_dispatch.cpp.o "$B/fuzz-lsan_off.o")
STUBS=()
[ -n "$SANITIZER_FLAGS" ] || STUBS=("$B/sancov_stubs.o")   # no sanitizer runtime → no SanCov callbacks

for t in fuzz_mavconn_parse fuzz_mavlink_msg; do
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$B/fuzz/$t.cpp.o" "${LIB_OBJS[@]}" $LIBS -o "/mayhem/$t"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS "$B/standalone_main.o" "${STUBS[@]}" "$B/fuzz/$t.cpp.o" "${LIB_OBJS[@]}" $LIBS \
    -o "/mayhem/$t-standalone"
done
