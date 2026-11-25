import Dependencies
import FoundationModels
import Ollama
import Synchronization
import Testing

@testable import olleh

@Suite(.enabled(if: FoundationModelsDependency.liveValue.isAvailable()))
struct SessionTests {
    private actor Transcript {
        var prompts: [String] = []

        func record(_ prompt: String) -> String {
            prompts.append(prompt)
            return prompts.joined(separator: "\n")
        }
    }

    private static func echoSession() -> FoundationModelsDependency.Session {
        let transcript = Transcript()
        return .init(
            prewarm: {},
            generate: { prompt, _ in await transcript.record(prompt) },
            streamGenerate: { prompt, _ in
                let response = await transcript.record(prompt)
                return AsyncThrowingStream { continuation in
                    continuation.yield(response)
                    continuation.finish()
                }
            }
        )
    }

    private let client = FoundationModelsDependency.live { _ in echoSession() }

    @Test func requestsShareTheModel() async throws {
        let models = Mutex<[SystemLanguageModel]>([])
        let client = FoundationModelsDependency.live { model in
            models.withLock { $0.append(model) }
            return Self.echoSession()
        }
        _ = try await client.generate("default", "first", .init())
        _ = try await client.generate("default", "second", .init())
        let reusedModel = models.withLock { $0.count == 2 && $0[0] === $0[1] }
        #expect(reusedModel)
    }

    @Test func independentRequestsUseOnlyTheirSuppliedHistory() async throws {
        for marker in ["first", "second"] {
            let messages: [Chat.Message] = [
                .system("instruction"), .user("question"), .assistant("answer"),
                .tool("result"), .user(marker),
            ]
            let expected = [
                "System: instruction", "User: question", "Assistant: answer", "Tool: result", "User: \(marker)",
            ].joined(separator: "\n\n")

            let stream = try await client.streamGenerate("default", marker, .init())
            let chatStream = try await client.streamChat("default", messages, .init())
            #expect(try await client.generate("default", marker, .init()) == marker)
            #expect(try await client.chat("default", messages, .init()) == expected)
            #expect(try await stream.reduce("", +) == marker)
            #expect(try await chatStream.reduce("", +) == expected)
        }
    }

    @Test func interactiveChatKeepsItsTurnsUntilCleared() async throws {
        let chat = withDependencies {
            $0.foundationModelsClient = client
        } operation: {
            ChatSession()
        }
        let first = try await chat.conversationSession()
        let stream = try await first.streamGenerate("first", .init())
        #expect(try await stream.reduce("", +) == "first")
        #expect(try await client.generate("default", "independent", .init()) == "independent")

        let second = try await chat.conversationSession()
        #expect(try await second.generate("second", .init()) == "first\nsecond")

        await chat.handleClearCommand()
        let cleared = try await chat.conversationSession()
        #expect(try await cleared.generate("third", .init()) == "third")
    }
}
