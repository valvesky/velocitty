/* Link-time stubs for cross-compiling. Not shipped; the target's libXi
 * satisfies these at runtime via DT_NEEDED soname libXi.so.6. */
#define S(name) void name(void) {}

S(XIFreeDeviceInfo)
S(XIQueryDevice)
S(XIQueryVersion)
S(XISelectEvents)
