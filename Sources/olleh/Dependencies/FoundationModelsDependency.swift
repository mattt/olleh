import Dependencies
import Foundation
import FoundationModels
import Ollama

struct FoundationModelsDependency: Sendable {
    enum Error: Swift.Error, LocalizedError {
        case notAvailable
        case invalidModel

        var errorDescription: String? {
            switch self {
            case .notAvailable:
                return
                    "Foundation Models framework is not available. Requires macOS 26.0+ on Apple Silicon."
            case .invalidModel:
                return "The specified model is not available."
            }
        }
    }

    var isAvailable: @Sendable () -> Bool
    var prewarm: @Sendable () async -> Void
    var listModels: @Sendable () async -> [String]
    var modelExists: @Sendable (_ name: String) async -> Bool
    var generate:
        @Sendable (_ model: String, _ prompt: String, _ parameters: [String: String]) async throws
            -> String
    var streamGenerate:
        @Sendable (_ model: String, _ prompt: String) async throws -> AsyncThrowingStream<
            String, Swift.Error
        >
    var chat: @Sendable (_ model: String, _ messages: [Chat.Message]) async throws -> String
}

// MARK: -

extension FoundationModelsDependency: DependencyKey {
    static let liveValue = {
        @available(macOS 26.0, *)
        actor Client {
            private var session: LanguageModelSession?

            private let isAvailable: Bool = ProcessInfo.processInfo.processorArchitecture == "arm64"

            private func getSession() async throws -> LanguageModelSession {
                if let session = self.session {
                    return session
                }

                let session = LanguageModelSession()
                self.session = session
                return session
            }

            private func checkAvailability() throws {
                guard isAvailable else {
                    throw FoundationModelsDependency.Error.notAvailable
                }
            }

            func prewarm() async {
                do {
                    let session = try await getSession()
                    session.prewarm()
                } catch {
                    // Ignore prewarming errors as the session will still work
                }
            }

            func generate(model: String, prompt: String, parameters: [String: Any] = [:])
                async throws
                -> String
            {
                try checkAvailability()
                let session = try await getSession()

                // Note: LanguageModelSession doesn't currently support parameter configuration
                // Parameters are ignored for now but kept for future API compatibility

                let response = try await session.respond(to: prompt)
                return response.content
            }

            func streamGenerate(model: String, prompt: String) async throws -> AsyncThrowingStream<
                String, Swift.Error
            > {
                try checkAvailability()
                let session = try await getSession()

                return AsyncThrowingStream { continuation in
                    Task {
                        do {
                            var lastSnapshotCount = 0
                            for try await snapshot in session.streamResponse(to: prompt) {
                                // Foundation Models emits cumulative snapshots, not deltas
                                // Extract only the new content since the last emission
                                if snapshot.count > lastSnapshotCount {
                                    let newContent = String(
                                        snapshot.dropFirst(lastSnapshotCount))
                                    continuation.yield(newContent)
                                    lastSnapshotCount = snapshot.count
                                }
                            }
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    }
                }
            }

            func chat(model: String, messages: [Chat.Message]) async throws -> String {
                try checkAvailability()
                let session = try await getSession()
                let prompt = prompt(for: messages)
                let response = try await session.respond(to: prompt)
                return response.content
            }

            private func prompt(for messages: [Chat.Message]) -> String {
                var result = ""
                result.reserveCapacity(messages.count * 128)

                for (index, message) in messages.enumerated() {
                    if index > 0 {
                        result += "\n\n"
                    }

                    switch message.role {
                    case .system:
                        result += "System: \(message.content)"
                    case .user:
                        result += "User: \(message.content)"
                    case .assistant:
                        result += "Assistant: \(message.content)"
                    case .tool:
                        result += "Tool: \(message.content)"
                    }
                }

                return result
            }
        }

        let client = Client()

        return FoundationModelsDependency(
            isAvailable: {
                // Foundation Models requires both macOS 26.0+ AND Apple Silicon
                if #available(macOS 26.0, *) {
                    return ProcessInfo.processInfo.processorArchitecture == "arm64"
                } else {
                    return false
                }
            },
            prewarm: {
                await client.prewarm()
            },
            listModels: {
                return ["default"]
            },
            modelExists: { name in
                return name == "default"
            },
            generate: { model, prompt, parameters in
                // Convert string parameters to Any for the actor method
                let anyParams = parameters.mapValues { $0 as Any }
                return try await client.generate(
                    model: model,
                    prompt: prompt,
                    parameters: anyParams
                )
            },
            streamGenerate: { model, prompt in
                try await client.streamGenerate(
                    model: model,
                    prompt: prompt
                )
            },
            chat: { model, messages in
                try await client.chat(
                    model: model,
                    messages: messages
                )
            }
        )
    }()

    static let testValue = FoundationModelsDependency(
        isAvailable: { true },
        prewarm: {},
        listModels: {
            return ["default"]
        },
        modelExists: { name in
            return name == "default"
        },
        generate: { _, prompt, _ in
            "Test response for: \(prompt)"
        },
        streamGenerate: { _, prompt in
            AsyncThrowingStream { continuation in
                continuation.yield("Test")
                continuation.yield(" streaming")
                continuation.yield(" response")
                continuation.yield(" for: \(prompt)")
                continuation.finish()
            }
        },
        chat: { _, messages in
            "Test chat response for \(messages.count) messages"
        }
    )
}

extension DependencyValues {
    var foundationModelsClient: FoundationModelsDependency {
        get { self[FoundationModelsDependency.self] }
        set { self[FoundationModelsDependency.self] = newValue }
    }
}

// MARK: -

extension ProcessInfo {
    fileprivate var processorArchitecture: String {
        var sysinfo = utsname()
        let result = uname(&sysinfo)

        guard result == 0 else { return "unknown" }

        let architecture = withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }

        return architecture
    }
}
