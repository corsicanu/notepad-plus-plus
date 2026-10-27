// pugixml from PowerEditor/src/pugixml, with our own configuration:
// upstream's pugiconfig.hpp enables std::from_chars for floats, which
// needs macOS 26. Pre-defining its include guard skips it.
#pragma once

#define HEADER_PUGICONFIG_HPP
#define PUGIXML_NO_XPATH
#define PUGIXML_HEADER_ONLY

#include "pugixml.hpp"
