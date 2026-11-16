#ifndef HUMMINGBIRD_TEST_BOOTSTRAP_H
#define HUMMINGBIRD_TEST_BOOTSTRAP_H

/// Defined in Swift by the HummingbirdKitTests target: records the user's
/// real Hummingbird data and registers the observer that fails the test run
/// if any test changes it.
void hummingbird_install_real_data_guard(void);

#endif
