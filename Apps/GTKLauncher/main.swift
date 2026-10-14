import Darwin
import Foundation

let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let executable = repository.appendingPathComponent(
    ".build/gtk/out/Products/Debug/Hummingbird-gtk"
).path
let nixCandidates = [
    "/run/current-system/sw/bin/nix",
    "/nix/var/nix/profiles/default/bin/nix",
]

guard let nix = nixCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
    fputs("Hummingbird GTK requires Nix.\n", stderr)
    exit(EXIT_FAILURE)
}
guard chdir(repository.path) == 0 else {
    perror("Could not enter the Hummingbird repository")
    exit(EXIT_FAILURE)
}

// Flake evaluation needs Git, but the project intentionally keeps it out of
// its development shell. Match the command-line workflow and provide Git in a
// throwaway shell while entering the real environment.
let arguments = [
    nix, "shell", "nixpkgs#git", "--command",
    "nix", "develop", "--command", executable,
]
var pointers: [UnsafeMutablePointer<CChar>?] = arguments.map { argument in
    argument.withCString { strdup($0) }
}
pointers.append(nil)
_ = pointers.withUnsafeMutableBufferPointer { buffer in
    execv(nix, buffer.baseAddress)
}
perror("Could not launch Hummingbird GTK")
exit(EXIT_FAILURE)
