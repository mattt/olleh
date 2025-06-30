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

                // Print header
                print(
                    "NAME".padding(toLength: 25, withPad: " ", startingAt: 0)
                        + "ID".padding(toLength: 15, withPad: " ", startingAt: 0)
                        + "SIZE".padding(toLength: 9, withPad: " ", startingAt: 0) + "MODIFIED")

                // Print models
                for model in models {
                    let sizeStr =
                        model.size > 0
                        ? ByteCountFormatter.string(fromByteCount: model.size, countStyle: .file)
                        : "N/A"
                    let modifiedStr = RelativeDateTimeFormatter().localizedString(
                        for: model.modifiedAt, relativeTo: Date())

                    // Create a short digest for the ID column
                    let shortDigest = String(model.digest.suffix(12))

                    print(
                        model.name.padding(toLength: 25, withPad: " ", startingAt: 0)
                            + shortDigest.padding(toLength: 15, withPad: " ", startingAt: 0)
                            + sizeStr.padding(toLength: 9, withPad: " ", startingAt: 0)
                            + modifiedStr)
                }
                group.leave()
            }

            group.wait()
        }
    }
}
