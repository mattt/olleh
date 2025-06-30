import ArgumentParser
import Dependencies
import Foundation
import Hummingbird
import HummingbirdCore
import Logging
import NIOCore
import Ollama

extension Olleh {
    struct Serve: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Start olleh"
        )

        @Option(help: "Host to listen on")
        var host: String = "127.0.0.1"

        @Option(help: "Port to listen on")
        var port: Int = 11941

        @Flag(help: "Enable verbose logging")
        var verbose: Bool = false

        func run() throws {
            let server = OllamaServer(host: host, port: port, verbose: verbose)

            let group = DispatchGroup()
            group.enter()

            Task {
                do {
                    try await server.start()
                } catch {
                    print("Server failed to start: \(error.localizedDescription)")
                    if verbose {
                        print("Error details: \(error)")
                    }
                }
                group.leave()
            }

            group.wait()
        }
    }
}

// MARK: -

private final actor OllamaServer: Sendable {
    let host: String
    let port: Int
    let verbose: Bool

    private let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let string = formatter.string(from: date)
            var container = encoder.singleValueContainer()
            try container.encode(string)
        }
        return encoder
    }()

    private let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = formatter.date(from: string) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid date format: \(string)"
                )
            }
            return date
        }
        return decoder
    }()

    init(host: String, port: Int, verbose: Bool) {
        self.host = host
        self.port = port
        self.verbose = verbose
    }

    @Dependency(\.foundationModelsClient) var foundationModelsClient

    private nonisolated func approximateTokenCount(for text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return max(1, text.count / 4)
    }

    func start() async throws {
        let router = Router()

        // Ollama-compatible API endpoints
        router.post("/api/generate") { request, context in
            context.logger.info("POST /api/generate")
            return try await self.generateCompletion(request: request, context: context)
        }

        router.post("/api/chat") { request, context in
            context.logger.info("POST /api/chat")
            return try await self.chatCompletion(request: request, context: context)
        }

        router.get("/api/tags") { request, context in
            context.logger.info("GET /api/tags")
            return try await self.listModels(context: context)
        }

        router.get("/api/show") { request, context in
            context.logger.info("GET /api/show")
            return try await self.showModel(request: request, context: context)
        }

        var logger = Logger(label: "olleh")
        logger.logLevel = verbose ? .debug : .info

        let app = Application(
            router: router,
            configuration: .init(
                address: .hostname(host, port: port)
            ),
            logger: logger
        )

        try await app.runService()
    }

    private func generateCompletion(request: Request, context: BasicRequestContext) async throws
        -> Response
    {
        let startTime = Date.now

        var bodyData = Data()
        for try await chunk in request.body.buffer(policy: .unbounded) {
            bodyData.append(contentsOf: chunk.readableBytesView)
        }

        let params = try jsonDecoder.decode([String: Value].self, from: bodyData)

        let model = params["model"]?.stringValue ?? "default"
        let prompt = params["prompt"]?.stringValue ?? ""
        let stream = params["stream"]?.boolValue ?? false

        guard foundationModelsClient.isAvailable() else {
            context.logger.error(
                "Foundation Models not available",
                metadata: [
                    "model": "\(model)",
                    "endpoint": "generate",
                ])
            throw FoundationModelsDependency.Error.notAvailable
        }

        // Extract generation parameters directly
        let generationParams: FoundationModelsDependency.Parameters
        do {
            generationParams = try jsonDecoder.decode(
                FoundationModelsDependency.Parameters.self,
                from: bodyData
            )
        } catch {
            context.logger.error(
                "Failed to decode generation parameters",
                metadata: [
                    "error": "\(error.localizedDescription)",
                    "model": "\(model)",
                ])
            throw error
        }

        // Calculate prompt token count approximation
        let promptTokenCount = approximateTokenCount(for: prompt)

        context.logger.debug(
            "Generate request",
            metadata: [
                "model": "\(model)",
                "stream": "\(stream)",
                "prompt_length": "\(prompt.count)",
            ])

        // Check if streaming is requested
        if stream {
            // Return streaming response
            let responseBody = ResponseBody { writer in
                do {
                    let loadStartTime = Date()
                    let streamedContent = try await self.foundationModelsClient.streamGenerate(
                        model, prompt, generationParams)
                    let loadDuration = Date().timeIntervalSince(loadStartTime)

                    var completionText = ""
                    let promptEvalStartTime = Date()

                    for try await chunk in streamedContent {
                        completionText += chunk
                        let response = Client.GenerateResponse(
                            model: Model.ID(rawValue: model) ?? "default",
                            createdAt: Date(),
                            response: chunk,
                            done: false
                        )

                        let data = try self.jsonEncoder.encode(response)
                        let line = String(data: data, encoding: .utf8)! + "\n"
                        try await writer.write(ByteBuffer(string: line))
                    }

                    let totalDuration = Date().timeIntervalSince(startTime)
                    let evalTokenCount = self.approximateTokenCount(for: completionText)

                    context.logger.debug(
                        "Generate streaming completed",
                        metadata: [
                            "duration": "\(String(format: "%.2fs", totalDuration))",
                            "tokens": "\(evalTokenCount)",
                        ])

                    // Send final "done" response
                    let finalResponse = Client.GenerateResponse(
                        model: Model.ID(rawValue: model) ?? "default",
                        createdAt: Date(),
                        response: "",
                        done: true,
                        context: nil,
                        thinking: nil,
                        totalDuration: totalDuration,
                        loadDuration: loadDuration,
                        promptEvalCount: promptTokenCount,
                        promptEvalDuration: Date().timeIntervalSince(promptEvalStartTime),
                        evalCount: evalTokenCount,
                        evalDuration: totalDuration - loadDuration
                    )

                    let finalData = try self.jsonEncoder.encode(finalResponse)
                    let finalLine = String(data: finalData, encoding: .utf8)! + "\n"
                    try await writer.write(ByteBuffer(string: finalLine))
                    try await writer.finish(nil)
                } catch {
                    context.logger.error(
                        "Generate streaming error",
                        metadata: [
                            "error": "\(error.localizedDescription)",
                            "model": "\(model)",
                            "stream": "true",
                        ])
                    // Send error response
                    let errorResponse = Client.GenerateResponse(
                        model: Model.ID(rawValue: model) ?? "default",
                        createdAt: Date(),
                        response: "Error: \(error.localizedDescription)",
                        done: true
                    )

                    let errorData = try self.jsonEncoder.encode(errorResponse)
                    let errorLine = String(data: errorData, encoding: .utf8)! + "\n"
                    try await writer.write(ByteBuffer(string: errorLine))
                    try await writer.finish(nil)
                }
            }

            return Response(
                status: .ok,
                headers: [.contentType: "application/x-ndjson"],
                body: responseBody
            )
        } else {
            // Non-streaming response
            let loadStartTime = Date()
            let response = try await foundationModelsClient.generate(
                model,
                prompt,
                generationParams
            )
            let loadDuration = Date().timeIntervalSince(loadStartTime)
            let totalDuration = Date().timeIntervalSince(startTime)

            let evalTokenCount = approximateTokenCount(for: response)

            context.logger.debug(
                "Generate completed",
                metadata: [
                    "duration": "\(String(format: "%.2fs", totalDuration))",
                    "tokens": "\(evalTokenCount)",
                ])

            let data = try jsonEncoder.encode(
                Client.GenerateResponse(
                    model: Model.ID(rawValue: model) ?? "default",
                    createdAt: Date(),
                    response: response,
                    done: true,
                    context: nil,
                    thinking: nil,
                    totalDuration: totalDuration,
                    loadDuration: loadDuration,
                    promptEvalCount: promptTokenCount,
                    promptEvalDuration: loadDuration,
                    evalCount: evalTokenCount,
                    evalDuration: totalDuration - loadDuration
                ))

            return Response(
                status: .ok,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: ByteBuffer(data: data))
            )
        }
    }

    private func chatCompletion(request: Request, context: some RequestContext) async throws
        -> Response
    {
        let startTime = Date()

        var bodyData = Data()
        for try await chunk in request.body.buffer(policy: .unbounded) {
            bodyData.append(contentsOf: chunk.readableBytesView)
        }

        let params = try jsonDecoder.decode([String: Value].self, from: bodyData)

        // Extract parameters
        let model = params["model"]?.stringValue ?? "default"
        let stream = params["stream"]?.boolValue ?? false

        guard foundationModelsClient.isAvailable() else {
            context.logger.error(
                "Foundation Models not available",
                metadata: [
                    "model": "\(model)",
                    "endpoint": "chat",
                ])
            throw FoundationModelsDependency.Error.notAvailable
        }

        let messages: [Chat.Message]
        do {
            if let messagesValue = params["messages"] {
                let data = try jsonEncoder.encode(messagesValue)
                messages = try jsonDecoder.decode([Chat.Message].self, from: data)
            } else {
                messages = []
            }
        } catch {
            context.logger.error(
                "Failed to decode chat messages",
                metadata: [
                    "error": "\(error.localizedDescription)",
                    "model": "\(model)",
                ])
            throw error
        }

        context.logger.debug(
            "Chat request",
            metadata: [
                "model": "\(model)",
                "stream": "\(stream)",
                "messages_count": "\(messages.count)",
            ])

        // Extract generation parameters directly
        let generationParams = try jsonDecoder.decode(
            FoundationModelsDependency.Parameters.self,
            from: bodyData
        )

        // Calculate prompt token count approximation
        let promptText = messages.map(\.content).joined(separator: "\n")
        let promptTokenCount = approximateTokenCount(for: promptText)

        if stream {
            // Return streaming response
            let responseBody = ResponseBody { writer in
                do {
                    let loadStartTime = Date()
                    let streamedContent = try await self.foundationModelsClient.streamChat(
                        model, messages, generationParams)
                    let loadDuration = Date().timeIntervalSince(loadStartTime)

                    var completionText = ""
                    let promptEvalStartTime = Date()

                    for try await chunk in streamedContent {
                        completionText += chunk
                        let response = Client.ChatResponse(
                            model: Model.ID(rawValue: model) ?? "default",
                            createdAt: Date(),
                            message: Chat.Message.assistant(chunk),
                            done: false,
                            totalDuration: nil,
                            loadDuration: loadDuration,
                            promptEvalCount: promptTokenCount,
                            promptEvalDuration: Date().timeIntervalSince(promptEvalStartTime),
                            evalCount: self.approximateTokenCount(for: completionText),
                            evalDuration: Date().timeIntervalSince(startTime) - loadDuration
                        )

                        let data = try self.jsonEncoder.encode(response)
                        let line = String(data: data, encoding: .utf8)! + "\n"
                        try await writer.write(ByteBuffer(string: line))
                    }

                    let totalDuration = Date().timeIntervalSince(startTime)
                    let evalTokenCount = self.approximateTokenCount(for: completionText)

                    context.logger.debug(
                        "Chat streaming completed",
                        metadata: [
                            "duration": "\(String(format: "%.2fs", totalDuration))",
                            "tokens": "\(evalTokenCount)",
                        ])

                    // Send final "done" response
                    let finalResponse = Client.ChatResponse(
                        model: Model.ID(rawValue: model) ?? "default",
                        createdAt: Date(),
                        message: Chat.Message.assistant(""),
                        done: true,
                        totalDuration: totalDuration,
                        loadDuration: loadDuration,
                        promptEvalCount: promptTokenCount,
                        promptEvalDuration: Date().timeIntervalSince(promptEvalStartTime),
                        evalCount: evalTokenCount,
                        evalDuration: totalDuration - loadDuration
                    )

                    let finalData = try self.jsonEncoder.encode(finalResponse)
                    let finalLine = String(data: finalData, encoding: .utf8)! + "\n"
                    try await writer.write(ByteBuffer(string: finalLine))
                    try await writer.finish(nil)
                } catch {
                    context.logger.error(
                        "Chat streaming error",
                        metadata: [
                            "error": "\(error.localizedDescription)",
                            "model": "\(model)",
                            "stream": "true",
                        ])
                    // Send error response
                    let errorResponse = Client.ChatResponse(
                        model: Model.ID(rawValue: model) ?? "default",
                        createdAt: Date(),
                        message: Chat.Message.assistant("Error: \(error.localizedDescription)"),
                        done: true
                    )

                    let errorData = try self.jsonEncoder.encode(errorResponse)
                    let errorLine = String(data: errorData, encoding: .utf8)! + "\n"
                    try await writer.write(ByteBuffer(string: errorLine))
                    try await writer.finish(nil)
                }
            }

            return Response(
                status: .ok,
                headers: [.contentType: "application/x-ndjson"],
                body: responseBody
            )
        } else {
            // Non-streaming response
            let loadStartTime = Date()
            let response = try await foundationModelsClient.chat(
                model,
                messages,
                generationParams
            )
            let loadDuration = Date().timeIntervalSince(loadStartTime)
            let totalDuration = Date().timeIntervalSince(startTime)

            let evalTokenCount = approximateTokenCount(for: response)

            context.logger.debug(
                "Chat completed",
                metadata: [
                    "duration": "\(String(format: "%.2fs", totalDuration))",
                    "tokens": "\(evalTokenCount)",
                ])

            let data = try jsonEncoder.encode(
                Client.ChatResponse(
                    model: Model.ID(rawValue: model) ?? "default",
                    createdAt: Date(),
                    message: Chat.Message.assistant(response),
                    done: true,
                    totalDuration: totalDuration,
                    loadDuration: loadDuration,
                    promptEvalCount: promptTokenCount,
                    promptEvalDuration: loadDuration,
                    evalCount: evalTokenCount,
                    evalDuration: totalDuration - loadDuration
                ))

            return Response(
                status: .ok,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: ByteBuffer(data: data))
            )
        }
    }

    private func listModels(context: some RequestContext) async throws -> Response {
        context.logger.debug("Listing available models")
        let models = await foundationModelsClient.listModels()

        let response = Client.ListModelsResponse(
            models: models.map {
                Client.ListModelsResponse.Model(
                    name: $0,
                    modifiedAt: iso8601Formatter.string(from: Date()),
                    size: 0,
                    digest: "",
                    details: Model.Details(
                        format: "apple",
                        family: "foundation",
                        families: ["foundation"],
                        parameterSize: "unknown",
                        quantizationLevel: "unknown",
                        parentModel: nil
                    )
                )
            }
        )

        let data = try jsonEncoder.encode(response)
        return Response(
            status: .ok,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(data: data))
        )
    }

    private func showModel(request: Request, context: some RequestContext) async throws -> Response
    {
        let modelName = request.uri.queryParameters["name"] ?? "default"
        context.logger.debug("Show model request", metadata: ["name": "\(modelName)"])

        let response = Client.ShowModelResponse(
            modelfile: "FROM apple/foundation-models",
            parameters: "{}",
            template: "{{ .Prompt }}",
            details: Model.Details(
                format: "apple",
                family: "foundation",
                families: ["foundation"],
                parameterSize: "unknown",
                quantizationLevel: "unknown",
                parentModel: nil
            ),
            info: ["license": .string("Apple Foundation Models")],
            capabilities: [.completion]
        )

        let data = try jsonEncoder.encode(response)
        return Response(
            status: .ok,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(data: data))
        )
    }

}
