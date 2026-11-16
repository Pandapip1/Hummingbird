#include "HummingbirdTestBootstrap.h"

// Runs when the test bundle is loaded, before XCTest starts the first test,
// so the guard's baseline predates every test and no test class has to opt in.
__attribute__((constructor))
static void hummingbird_test_bootstrap(void) {
    hummingbird_install_real_data_guard();
}
