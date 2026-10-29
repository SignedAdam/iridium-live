#ifndef IRIDIUM_AUDIO_GUARD_H
#define IRIDIUM_AUDIO_GUARD_H

#include <stdbool.h>
#include <stddef.h>

/// Runs `block` inside an Objective-C @try/@catch.
///
/// AVAudioEngine raises NSExceptions (bad tap format, unavailable device) that Swift cannot
/// catch, which aborts the process. Returns true when the block finished, false when an
/// exception was caught, in which case a UTF-8 description is written into `reason`.
bool IridiumRunCatchingNSException(void (^block)(void), char *reason, size_t capacity);

#endif
