// Decodes a payload directly as one MAVLink message class (any dialect libmavconn includes), skipping
// the framing/CRC layer that fuzz_mavconn_parse needs valid frames to get past: deserialize, YAML
// rendering and re-serialization of the generated message classes mavros plugins consume.
#include <cstdint>
#include <cstring>

#include <console_bridge/console.h>

#include "msg_dispatch.hpp"

extern "C" int LLVMFuzzerInitialize(int *, char ***)
{
  console_bridge::setLogLevel(console_bridge::CONSOLE_BRIDGE_LOG_NONE);
  return 0;
}

// data[0..1] = message class index, rest = wire payload (<= 255 bytes; MAVLink v2 sends it
// trailing-zero-truncated, so a short payload is zero-extended like the frame parser does).
extern "C" int LLVMFuzzerTestOneInput(const uint8_t * data, size_t size)
{
  if (size < 2 || size - 2 > MAVLINK_MAX_PAYLOAD_LEN) {
    return -1;
  }
  const size_t idx = data[0] | (size_t(data[1]) << 8);

  mavlink::mavlink_message_t msg{};
  msg.len = static_cast<uint8_t>(size - 2);
  std::memcpy(msg.payload64, data + 2, size - 2);

  return mavros_fuzz::decode_by_index(idx, &msg) == size_t(-1) ? 1 : 0;
}
