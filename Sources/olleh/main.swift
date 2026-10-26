import ArgumentParser
import Foundation

struct Olleh: ParsableCommand {
    static let version = "1.2.0"

    static let configuration = CommandConfiguration(
        commandName: "olleh",
        abstract: "Ollama-compatible CLI for Apple Foundation Models",
        version: version,
        subcommands: [Serve.self, Run.self, List.self, Show.self, Check.self]
    )
}

Olleh.main()
