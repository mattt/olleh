import Dependencies
import Foundation
import FoundationModels
import Ollama

struct FoundationModelsDependency: Sendable {
    struct ModelInfo: Codable, Sendable {
        let name: String
        let digest: String
        let size: Int64
        let modifiedAt: Date
        let details: Model.Details
        let capabilities: Set<Model.Capability>
        let license: String
        let temperature: Double
        let contextLength: Int
        let embeddingLength: Int

        // https://machinelearning.apple.com/research/apple-foundation-models-2025-updates
        static let `default` = ModelInfo(
            name: "default",
            digest: "",
            size: 0,
            modifiedAt: Date(timeIntervalSince1970: 1_749_487_260),  // June 9, 2025 at 9:41 AM PST
            details: Model.Details(
                format: "apple",
                family: "foundation",
                families: ["foundation"],
                parameterSize: "3B",
                quantizationLevel: "2b-qat",
                parentModel: nil
            ),
            capabilities: [.completion, .tools],
            license: "Apple Terms of Use",
            temperature: 0.7,
            contextLength: 65536,
            embeddingLength: 2048
        )

    }

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

    struct Parameters: Codable {
        var seed: Int?
        var temperature: Double?
        var topP: Double?
        var maxTokens: Int?
        var stop: String?

        enum CodingKeys: String, CodingKey {
            case seed
            case temperature
            case topP = "top_p"
            case maxTokens = "max_tokens"
            case stop
        }

        @available(macOS 26.0, *)
        var generationOptions: GenerationOptions {
            .init(
                sampling: seed.map { .random(probabilityThreshold: topP ?? 0.9, seed: UInt64($0)) }
                    ?? topP.map { .random(probabilityThreshold: $0) },
                temperature: temperature,
                maximumResponseTokens: maxTokens
            )
        }
    }

    var isAvailable: @Sendable () -> Bool
    var prewarm: @Sendable () async -> Void
    var listModels: @Sendable () async -> [ModelInfo]
    var modelExists: @Sendable (_ name: String) async -> Bool
    var getModelInfo: @Sendable (_ name: String) async -> ModelInfo?
    var generate:
        @Sendable (_ model: String, _ prompt: String, _ parameters: Parameters) async throws
            -> String
    var streamGenerate:
        @Sendable (_ model: String, _ prompt: String, _ parameters: Parameters) async throws ->
            AsyncThrowingStream<
                String, Swift.Error
            >
    var chat:
        @Sendable (_ model: String, _ messages: [Chat.Message], _ parameters: Parameters)
            async throws -> String
    var streamChat:
        @Sendable (_ model: String, _ messages: [Chat.Message], _ parameters: Parameters)
            async throws -> AsyncThrowingStream<String, Swift.Error>
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

            func generate(model: String, prompt: String, parameters: Parameters = Parameters())
                async throws
                -> String
            {
                try checkAvailability()
                let session = try await getSession()

                let response = try await session.respond(
                    to: prompt, options: parameters.generationOptions)
                return response.content
            }

            func streamGenerate(
                model: String, prompt: String, parameters: Parameters = Parameters()
            ) async throws -> AsyncThrowingStream<
                String, Swift.Error
            > {
                try checkAvailability()
                let session = try await getSession()

                return AsyncThrowingStream { continuation in
                    Task {
                        do {
                            var lastSnapshotCount = 0
                            for try await snapshot in session.streamResponse(
                                to: prompt, options: parameters.generationOptions)
                            {
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

            func chat(
                model: String, messages: [Chat.Message], parameters: Parameters = Parameters()
            ) async throws -> String {
                try checkAvailability()
                let session = try await getSession()
                let prompt = prompt(for: messages)
                let response = try await session.respond(
                    to: prompt, options: parameters.generationOptions)
                return response.content
            }

            func streamChat(
                model: String, messages: [Chat.Message], parameters: Parameters = Parameters()
            ) async throws -> AsyncThrowingStream<String, Swift.Error> {
                try checkAvailability()
                let prompt = prompt(for: messages)
                return try await streamGenerate(
                    model: model, prompt: prompt, parameters: parameters)
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
                return [ModelInfo.default]
            },
            modelExists: { name in
                return name == "default"
            },
            getModelInfo: { name in
                return name == "default" ? ModelInfo.default : nil
            },
            generate: { model, prompt, parameters in
                return try await client.generate(
                    model: model,
                    prompt: prompt,
                    parameters: parameters
                )
            },
            streamGenerate: { model, prompt, parameters in
                try await client.streamGenerate(
                    model: model,
                    prompt: prompt,
                    parameters: parameters
                )
            },
            chat: { model, messages, parameters in
                try await client.chat(
                    model: model,
                    messages: messages,
                    parameters: parameters
                )
            },
            streamChat: { model, messages, parameters in
                try await client.streamChat(
                    model: model,
                    messages: messages,
                    parameters: parameters
                )
            }
        )
    }()

    static let testValue = FoundationModelsDependency(
        isAvailable: { true },
        prewarm: {},
        listModels: {
            return [ModelInfo.default]
        },
        modelExists: { name in
            return name == "default"
        },
        getModelInfo: { name in
            return name == "default" ? ModelInfo.default : nil
        },
        generate: { _, prompt, _ in
            "Test response for: \(prompt)"
        },
        streamGenerate: { _, prompt, _ in
            AsyncThrowingStream { continuation in
                continuation.yield("Test")
                continuation.yield(" streaming")
                continuation.yield(" response")
                continuation.yield(" for: \(prompt)")
                continuation.finish()
            }
        },
        chat: { _, messages, _ in
            "Test chat response for \(messages.count) messages"
        },
        streamChat: { _, messages, _ in
            AsyncThrowingStream { continuation in
                continuation.yield("Test streaming chat response")
                continuation.yield(" for \(messages.count) messages")
                continuation.finish()
            }
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
