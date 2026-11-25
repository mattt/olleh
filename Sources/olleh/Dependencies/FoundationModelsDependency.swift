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

    struct Session: Sendable {
        var prewarm: @Sendable () -> Void
        var generate: @Sendable (String, Parameters) async throws -> String
        var streamGenerate:
            @Sendable (String, Parameters) async throws -> AsyncThrowingStream<String, Swift.Error>

        static func live(model: SystemLanguageModel) -> Self {
            let session = LanguageModelSession(model: model)
            return Self(
                prewarm: { session.prewarm() },
                generate: { prompt, parameters in
                    let response = try await session.respond(
                        to: prompt, options: parameters.generationOptions)
                    return response.content
                },
                streamGenerate: { prompt, parameters in
                    AsyncThrowingStream { continuation in
                        Task {
                            do {
                                var lastContentLength = 0
                                for try await snapshot in session.streamResponse(
                                    to: prompt, options: parameters.generationOptions)
                                {
                                    // Foundation Models emits cumulative snapshots, not deltas
                                    // Extract only the new content since the last emission
                                    let currentContent = snapshot.content
                                    if currentContent.count > lastContentLength {
                                        let newContent = String(currentContent.dropFirst(lastContentLength))
                                        continuation.yield(newContent)
                                        lastContentLength = currentContent.count
                                    }
                                }
                                continuation.finish()
                            } catch {
                                continuation.finish(throwing: error)
                            }
                        }
                    }
                }
            )
        }
    }

    var isAvailable: @Sendable () -> Bool
    var loadAdapter: @Sendable (_ path: String) async throws -> Void
    var makeSession: @Sendable () async throws -> Session
    var listModels: @Sendable () async -> [ModelInfo]
    var modelExists: @Sendable (_ name: String) async -> Bool
    var getModelInfo: @Sendable (_ name: String) async -> ModelInfo?

    func generate(_ model: String, _ prompt: String, _ parameters: Parameters) async throws -> String {
        try await makeSession().generate(prompt, parameters)
    }

    func streamGenerate(_ model: String, _ prompt: String, _ parameters: Parameters) async throws
        -> AsyncThrowingStream<String, Swift.Error>
    {
        try await makeSession().streamGenerate(prompt, parameters)
    }

    func chat(_ model: String, _ messages: [Chat.Message], _ parameters: Parameters) async throws -> String {
        try await generate(model, prompt(for: messages), parameters)
    }

    func streamChat(_ model: String, _ messages: [Chat.Message], _ parameters: Parameters) async throws
        -> AsyncThrowingStream<String, Swift.Error>
    {
        try await streamGenerate(model, prompt(for: messages), parameters)
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

// MARK: -

extension FoundationModelsDependency: DependencyKey {
    static let liveValue = live()

    static func live(
        makeSession: @escaping @Sendable (SystemLanguageModel) -> Session = Session.live
    ) -> Self {
        actor ModelStore {
            lazy var model = SystemLanguageModel.default

            func loadAdapter(from path: String) throws {
                let adapter = try SystemLanguageModel.Adapter(fileURL: URL(filePath: path))
                model = SystemLanguageModel(adapter: adapter)
            }
        }

        let store = ModelStore()
        let isAvailable: @Sendable () -> Bool = {
            ProcessInfo.processInfo.processorArchitecture == "arm64"
        }

        return Self(
            isAvailable: isAvailable,
            loadAdapter: { try await store.loadAdapter(from: $0) },
            makeSession: {
                guard isAvailable() else { throw Error.notAvailable }
                return await makeSession(store.model)
            },
            listModels: { [ModelInfo.default] },
            modelExists: { $0 == "default" },
            getModelInfo: { $0 == "default" ? ModelInfo.default : nil }
        )
    }

    static let testValue = FoundationModelsDependency(
        isAvailable: { true },
        loadAdapter: { _ in },
        makeSession: {
            Session(
                prewarm: {},
                generate: { prompt, _ in "Test response for: \(prompt)" },
                streamGenerate: { prompt, _ in
                    AsyncThrowingStream { continuation in
                        continuation.yield("Test")
                        continuation.yield(" streaming")
                        continuation.yield(" response")
                        continuation.yield(" for: \(prompt)")
                        continuation.finish()
                    }
                }
            )
        },
        listModels: {
            return [ModelInfo.default]
        },
        modelExists: { name in
            return name == "default"
        },
        getModelInfo: { name in
            return name == "default" ? ModelInfo.default : nil
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
