import Foundation

actor Spinner {
    private let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    private var index = 0
    private var task: Task<Void, Never>?

    func start() {
        task = Task {
            while !Task.isCancelled {
                let frame = frames[index]
                update(frame)
                index = (index + 1) % frames.count

                do {
                    try await Task.sleep(for: .milliseconds(100), tolerance: .milliseconds(10))
                } catch {
                    break
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        update()  // Clear the line by updating with empty content
    }

    private func update(_ content: String = "") {
        // \r - Carriage return: moves cursor to beginning of current line
        // \u{001B}[K - ANSI escape sequence: clears from cursor to end of line
        // This combination allows us to overwrite the current line cleanly
        print("\r\u{001B}[K\(content)", terminator: "")

        // Force the output buffer to flush immediately.
        // Without this, the spinner might not appear or update smoothly
        // because stdout is line-buffered by default
        fflush(stdout)
    }
}

func withLoadingAnimation<T>(
    _ operation: @escaping @Sendable () async throws -> T
) async rethrows -> T {
    let spinner = Spinner()
    await spinner.start()

    let result = try await operation()

    await spinner.stop()
    return result
}
