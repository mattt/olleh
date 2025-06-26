import ArgumentParser
import Dependencies
import Foundation

extension Olleh {
    struct Check: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Check availability"
        )

        func run() throws {
            @Dependency(\.foundationModelsClient) var foundationModelsClient
            
            let isAvailable = foundationModelsClient.isAvailable()
            print(isAvailable ? "Foundation Models available" : "Foundation Models not available")
        }
    }
}
