import ArgumentParser
import Dependencies
import Foundation

extension Olleh {
    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List models"
        )

        func run() throws {
            @Dependency(\.foundationModelsClient) var foundationModelsClient

            let group = DispatchGroup()
            group.enter()

            Task {
                let models = await foundationModelsClient.listModels()
                for model in models {
                    print(model)
                }
                group.leave()
            }

            group.wait()
        }
    }
}
