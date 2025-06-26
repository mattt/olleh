import Foundation

func withLoadingAnimation<T>(
    _ operation: @escaping @Sendable () async throws -> T
) async rethrows -> T {
    let spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    let spinnerTask = Task {
        var frameIndex = 0
        while !Task.isCancelled {
            print("\r\u{001B}[K", terminator: "")  // Clear line
            print("\(spinnerFrames[frameIndex])", terminator: "")
            fflush(stdout)  // Force output to appear immediately
            frameIndex = (frameIndex + 1) % spinnerFrames.count

            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                break
            }
        }
    }

    let result = try await operation()
    spinnerTask.cancel()

    print("\r\u{001B}[K", terminator: "")  // Clear line
    fflush(stdout)  // Ensure line is cleared immediately
    return result
}
