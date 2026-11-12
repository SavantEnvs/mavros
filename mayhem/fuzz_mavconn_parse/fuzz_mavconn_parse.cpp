// Feeds a raw byte stream through libmavconn's frame parser (MAVConnInterface::parse_buffer: v1/v2
// framing, CRC, optional v2 signing) exactly as the UDP/TCP/serial transports do, then decodes every
// frame it accepts the way a mavros plugin would.
#include <array>
#include <cstdint>
#include <vector>

#include <console_bridge/console.h>

#include "mavconn/interface.hpp"
#include "msg_dispatch.hpp"

using mavconn::Framing;
using mavconn::MAVConnInterface;

namespace
{
class FuzzConn : public MAVConnInterface
{
public:
  using MAVConnInterface::MAVConnInterface;
  using MAVConnInterface::parse_buffer;

  void connect(const ReceivedCb &, const ClosedCb & = ClosedCb()) override {}
  void close() override {}
  void send_message(const mavlink::mavlink_message_t *) override {}
  void send_message(const mavlink::Message &, const uint8_t) override {}
  void send_bytes(const uint8_t *, size_t) override {}
  bool is_open() override {return true;}
};

// Fixed key and timestamp: signature checking must not depend on the wall clock.
constexpr std::array<uint8_t, 32> kSigningKey = {
  0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
  0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f};

bool accept_unsigned(const mavlink::mavlink_status_t *, uint32_t) {return true;}
}  // namespace

extern "C" int LLVMFuzzerInitialize(int *, char ***)
{
  console_bridge::setLogLevel(console_bridge::CONSOLE_BRIDGE_LOG_NONE);
  return 0;
}

// data[0]: bit0 = signing on, bit1 = accept unsigned frames, bit2 = reply as MAVLink v1. Rest = stream.
extern "C" int LLVMFuzzerTestOneInput(const uint8_t * data, size_t size)
{
  if (size < 1) {
    return -1;
  }
  const uint8_t flags = data[0];

  FuzzConn conn(1, 240);
  if (flags & 1) {
    conn.setup_signing(kSigningKey, false, 0, 0);
    if (flags & 2) {
      conn.set_accept_unsigned_callback(&accept_unsigned);
    }
  }
  if (flags & 4) {
    conn.set_protocol_version(mavconn::Protocol::V10);
  }

  size_t sink = 0;
  conn.message_received_cb =
    [&sink](const mavlink::mavlink_message_t * msg, const Framing framing) {
      if (framing == Framing::ok) {
        sink += mavros_fuzz::decode_by_id(msg);
      }
    };

  std::vector<uint8_t> buf(data + 1, data + size);
  conn.parse_buffer("fuzz", buf.data(), buf.size(), buf.size());
  (void)conn.get_status();
  (void)conn.get_iostat();
  return sink == size_t(-1) ? 1 : 0;
}
