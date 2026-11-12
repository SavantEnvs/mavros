#pragma once
#include <cstddef>
#include <cstdint>

#include "mavconn/mavlink_dialect.hpp"

namespace mavros_fuzz
{
// Number of (dialect, message) classes libmavconn's dialect header makes available to mavros plugins.
size_t message_type_count();
// What a mavros plugin does with a received frame: deserialize every message class whose id matches,
// render it to YAML and serialize it back. Returns a checksum so nothing is optimized away.
size_t decode_by_id(const mavlink::mavlink_message_t * msg);
// Same, for the idx-th message class (idx is taken modulo message_type_count()).
size_t decode_by_index(size_t idx, const mavlink::mavlink_message_t * msg);
}  // namespace mavros_fuzz
