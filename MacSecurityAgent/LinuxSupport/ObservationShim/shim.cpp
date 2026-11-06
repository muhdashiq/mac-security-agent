// Linux-only workaround for a Swift 6.0.x toolchain bug: libswiftObservation.so
// references `swift::threading::fatal(const char *, ...)`, which libswiftCore
// does not export on Linux, so any test binary using `@Observable` fails to
// link. This target is only part of the package graph on Linux (CI); it is
// never built for the macOS app.
#include <cstdarg>
#include <cstdio>
#include <cstdlib>

namespace swift {
namespace threading {
[[noreturn]] void fatal(const char *message, ...) {
    va_list arguments;
    va_start(arguments, message);
    std::vfprintf(stderr, message, arguments);
    va_end(arguments);
    std::abort();
}
} // namespace threading
} // namespace swift
