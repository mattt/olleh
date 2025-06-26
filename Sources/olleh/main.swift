import ArgumentParser
import Foundation

struct Olleh: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "olleh",
        abstract: "Ollama-compatible CLI for Apple Foundation Models",
        version: "1.0.0",
        subcommands: [Serve.self, Run.self, List.self, Check.self]
    )
}

Olleh.main()
