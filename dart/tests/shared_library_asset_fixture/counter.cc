// One count per loaded image of this library.
static int count = 0;

extern "C" int bump() { return ++count; }
