import ArgumentParser
import Dependencies
import Foundation
import Ollama

extension Olleh {
    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show model information"
        )

        @Argument(help: "Model name to show")
        var model: String

        func run() throws {
            @Dependency(\.foundationModelsClient) var foundationModelsClient

            let group = DispatchGroup()
            group.enter()

            Task {
                if let modelInfo = await foundationModelsClient.getModelInfo(model) {
                    printModelInfo(modelInfo)
                } else {
                    print("Error: model '\(model)' not found")
                }
                group.leave()
            }

            group.wait()
        }

        private func printModelInfo(_ model: FoundationModelsDependency.ModelInfo) {
            print("  Model")
            print("    architecture        \(model.details.family)")
            print("    parameters          \(model.details.parameterSize)")
            print("    context length      \(model.contextLength)")
            print("    embedding length    \(model.embeddingLength)")
            print("    quantization        \(model.details.quantizationLevel)")
            print("")
            print("  Capabilities")
            for capability in model.capabilities {
                print("    \(capability.rawValue)")
            }
            print("")
            print("  Parameters")
            print("    temperature    \(model.temperature)")
            print("")
            print("  License")
            print("    \(model.license)")
        }
    }
}
