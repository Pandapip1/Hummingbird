import ATAppSync

/// One at-rest sealer for the whole test run, so files reopened by later
/// instances (a simulated relaunch) open with the same key.
let testAtRestSealer = AtRestSealer.ephemeral(purpose: "tests")

/// The keyring tests' stores use: keys in memory only.
let testAtRestKeyring = AtRestKeyring.ephemeral()
