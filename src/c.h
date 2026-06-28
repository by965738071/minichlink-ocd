#include "minichlink.h"

// orig_main is defined in minichlink-patched.c (a patched copy of minichlink.c
// where main() has been renamed to orig_main() at configure time).
int orig_main(int argc, char **argv);
