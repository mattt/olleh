import ArgumentParser
import Dependencies
import Foundation
import Hummingbird
import HummingbirdCore
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
        var port: Int = 43110

        func run() throws {
            let server = OllamaServer(host: host, port: port)

            let group = DispatchGroup()
            group.enter()

            Task {
                do {
                    try await server.start()
                } catch {
                    print("Server error: \(error)")
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

    init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    @Dependency(\.foundationModelsClient) var foundationModelsClient

    func start() async throws {
        let router = Router()

        // Ollama-compatible API endpoints
        router.post("/api/generate") { request, context in
            return try await self.generateCompletion(request: request)
        }

        router.post("/api/chat") { request, context in
            return try await self.chatCompletion(request: request)
        }

        router.get("/api/tags") { request, context in
            let response = try await self.listModels()
            let data = try JSONEncoder().encode(response)
            return Response(
                status: .ok,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: ByteBuffer(data: data))
            )
        }

        router.get("/api/show") { request, context in
            let response = try await self.showModel(request: request)
            let data = try JSONEncoder().encode(response)
            return Response(
                status: .ok,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: ByteBuffer(data: data))
            )
        }

        let app = Application(
            router: router,
            configuration: .init(
                address: .hostname(host, port: port)
            )
        )

        print("Starting Olleh server on \(host):\(port)")
        try await app.runService()
    }

    private func listModels() async throws -> Client.ListModelsResponse {
        let models = await foundationModelsClient.listModels()

        return Client.ListModelsResponse(
            models: models.map {
                Client.ListModelsResponse.Model(
                    name: $0,
                    modifiedAt: ISO8601DateFormatter().string(from: Date()),
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
    }

    private func generateCompletion(request: Request) async throws -> Response {
        var bodyData = Data()
        for try await chunk in request.body.buffer(policy: .unbounded) {
            bodyData.append(contentsOf: chunk.readableBytesView)
        }

        let params = try JSONDecoder().decode([String: Value].self, from: bodyData)

        guard foundationModelsClient.isAvailable() else {
            throw FoundationModelsDependency.Error.notAvailable
        }

        // Extract parameters
        let model = params["model"]?.stringValue ?? "default"
        let prompt = params["prompt"]?.stringValue ?? ""
        let stream = params["stream"]?.boolValue ?? false

        // Extract generation parameters directly
        let generationParams = try JSONDecoder().decode(
            FoundationModelsDependency.Parameters.self,
            from: bodyData
        )

        // Check if streaming is requested
        if stream {
            // Return streaming response
            let responseBody = ResponseBody { writer in
                do {
                    let startTime = Date()
                    let streamedContent = try await self.foundationModelsClient.streamGenerate(
                        model, prompt, generationParams)

                    for try await chunk in streamedContent {
                        let response = Client.GenerateResponse(
                            model: Model.ID(rawValue: model) ?? "default",
                            createdAt: Date(),
                            response: chunk,
                            done: false,
                            context: nil,
                            thinking: nil,
                            totalDuration: nil,
                            loadDuration: nil,
                            promptEvalCount: nil,
                            promptEvalDuration: nil,
                            evalCount: nil,
                            evalDuration: nil
                        )

                        let data = try JSONEncoder().encode(response)
                        let line = String(data: data, encoding: .utf8)! + "\n"
                        try await writer.write(ByteBuffer(string: line))
                    }

                    // Send final "done" response
                    let finalResponse = Client.GenerateResponse(
                        model: Model.ID(rawValue: model) ?? "default",
                        createdAt: Date(),
                        response: "",
                        done: true,
                        context: nil,
                        thinking: nil,
                        totalDuration: Date().timeIntervalSince(startTime),
                        loadDuration: nil,
                        promptEvalCount: nil,
                        promptEvalDuration: nil,
                        evalCount: nil,
                        evalDuration: nil
                    )

                    let finalData = try JSONEncoder().encode(finalResponse)
                    let finalLine = String(data: finalData, encoding: .utf8)! + "\n"
                    try await writer.write(ByteBuffer(string: finalLine))
                    try await writer.finish(nil)
                } catch {
                    // Send error response
                    let errorResponse = Client.GenerateResponse(
                        model: Model.ID(rawValue: model) ?? "default",
                        createdAt: Date(),
                        response: "Error: \(error.localizedDescription)",
                        done: true,
                        context: nil,
                        thinking: nil,
                        totalDuration: nil,
                        loadDuration: nil,
                        promptEvalCount: nil,
                        promptEvalDuration: nil,
                        evalCount: nil,
                        evalDuration: nil
                    )

                    let errorData = try JSONEncoder().encode(errorResponse)
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
            let response = try await foundationModelsClient.generate(
                model,
                prompt,
                generationParams
            )

            let data = try JSONEncoder().encode(
                Client.GenerateResponse(
                    model: Model.ID(rawValue: model) ?? "default",
                    createdAt: Date(),
                    response: response,
                    done: true,
                    context: nil,
                    thinking: nil,
                    totalDuration: nil,
                    loadDuration: nil,
                    promptEvalCount: nil,
                    promptEvalDuration: nil,
                    evalCount: nil,
                    evalDuration: nil
                ))

            return Response(
                status: .ok,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: ByteBuffer(data: data))
            )
        }
    }

    private func chatCompletion(request: Request) async throws -> Response {
        var bodyData = Data()
        for try await chunk in request.body.buffer(policy: .unbounded) {
            bodyData.append(contentsOf: chunk.readableBytesView)
        }

        let params = try JSONDecoder().decode([String: Value].self, from: bodyData)

        guard foundationModelsClient.isAvailable() else {
            throw FoundationModelsDependency.Error.notAvailable
        }

        // Extract parameters
        let model = params["model"]?.stringValue ?? "default"
        let stream = params["stream"]?.boolValue ?? false
        let messages: [Chat.Message]
        if let messagesValue = params["messages"] {
            let data = try JSONEncoder().encode(messagesValue)
            messages = try JSONDecoder().decode([Chat.Message].self, from: data)
        } else {
            messages = []
        }

        // Extract generation parameters directly
        let generationParams = try JSONDecoder().decode(
            FoundationModelsDependency.Parameters.self,
            from: bodyData
        )

        if stream {
            // Return streaming response
            let responseBody = ResponseBody { writer in
                do {
                    let startTime = Date()
                    let streamedContent = try await self.foundationModelsClient.streamChat(
                        model, messages, generationParams)

                    for try await chunk in streamedContent {
                        let response = Client.ChatResponse(
                            model: Model.ID(rawValue: model) ?? "default",
                            createdAt: Date(),
                            message: Chat.Message.assistant(chunk),
                            done: false,
                            totalDuration: nil,
                            loadDuration: nil,
                            promptEvalCount: nil,
                            promptEvalDuration: nil,
                            evalCount: nil,
                            evalDuration: nil
                        )

                        let data = try JSONEncoder().encode(response)
                        let line = String(data: data, encoding: .utf8)! + "\n"
                        try await writer.write(ByteBuffer(string: line))
                    }

                    // Send final "done" response
                    let finalResponse = Client.ChatResponse(
                        model: Model.ID(rawValue: model) ?? "default",
                        createdAt: Date(),
                        message: Chat.Message.assistant(""),
                        done: true,
                        totalDuration: Date().timeIntervalSince(startTime),
                        loadDuration: nil,
                        promptEvalCount: nil,
                        promptEvalDuration: nil,
                        evalCount: nil,
                        evalDuration: nil
                    )

                    let finalData = try JSONEncoder().encode(finalResponse)
                    let finalLine = String(data: finalData, encoding: .utf8)! + "\n"
                    try await writer.write(ByteBuffer(string: finalLine))
                    try await writer.finish(nil)
                } catch {
                    // Send error response
                    let errorResponse = Client.ChatResponse(
                        model: Model.ID(rawValue: model) ?? "default",
                        createdAt: Date(),
                        message: Chat.Message.assistant("Error: \(error.localizedDescription)"),
                        done: true,
                        totalDuration: nil,
                        loadDuration: nil,
                        promptEvalCount: nil,
                        promptEvalDuration: nil,
                        evalCount: nil,
                        evalDuration: nil
                    )

                    let errorData = try JSONEncoder().encode(errorResponse)
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
            let response = try await foundationModelsClient.chat(
                model,
                messages,
                generationParams
            )

            let data = try JSONEncoder().encode(
                Client.ChatResponse(
                    model: Model.ID(rawValue: model) ?? "default",
                    createdAt: Date(),
                    message: Chat.Message.assistant(response),
                    done: true,
                    totalDuration: nil,
                    loadDuration: nil,
                    promptEvalCount: nil,
                    promptEvalDuration: nil,
                    evalCount: nil,
                    evalDuration: nil
                ))

            return Response(
                status: .ok,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: ByteBuffer(data: data))
            )
        }
    }

    private func showModel(request: Request) async throws -> Client.ShowModelResponse {
        _ = request.uri.queryParameters["name"] ?? "default"
        return Client.ShowModelResponse(
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
    }

}
