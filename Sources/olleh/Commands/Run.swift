import ArgumentParser
import Bestline
import Dependencies
import Foundation

import enum Ollama.Value

extension Olleh {
    struct Run: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Run a model interactively",
            discussion: """
                Start an interactive chat session with the specified model.

                You can customize the chat behavior using various options:
                - Set initial system message with --system
                - Configure sampling parameters like --temperature and --top-p
                - Enable verbose output with --verbose
                - Format output as JSON with --format

                During the chat session, use these commands:
                - /set parameter <name> <value>  Set generation parameters
                - /set system <message>          Set system message  
                - /set verbose/quiet             Toggle verbose mode
                - /show                          Show current settings
                - /clear                         Clear session context
                - /help or /?                    Show help
                - /bye                           Exit
                """
        )

        @Argument(help: "Model name to run")
        var model: String = "default"

        // Session Settings
        @Option(name: .long, help: "Initial system message for the chat session")
        var system: String = ""

        @Flag(name: .long, help: "Enable chat history (default: true)")
        var history: Bool = false

        @Flag(name: .long, help: "Disable chat history")
        var noHistory: Bool = false

        @Flag(name: .long, help: "Enable word wrapping (default: true)")
        var wordwrap: Bool = false

        @Flag(name: .long, help: "Disable word wrapping")
        var noWordwrap: Bool = false

        @Flag(name: .long, help: "Enable JSON formatting")
        var format: Bool = false

        @Flag(name: .long, help: "Enable verbose output")
        var verbose: Bool = false

        // Generation Parameters
        @Option(name: .long, help: "Random number seed for reproducible output")
        var seed: Int?

        @Option(name: .long, help: "Sampling temperature (0.0-2.0, higher = more creative)")
        var temperature: Double?

        @Option(name: .customLong("top-p"), help: "Nucleus sampling probability (0.0-1.0)")
        var topP: Double?

        @Option(name: .customLong("max-tokens"), help: "Maximum tokens to generate")
        var maxTokens: Int?

        @Option(name: .long, help: "Stop sequences (comma-separated)")
        var stop: String?

        @Option(name: .long, help: "Path to .fmadapter file to load")
        var load: String?

        func validate() throws {
            if let temp = temperature {
                guard temp >= 0.0 && temp <= 2.0 else {
                    throw ValidationError("Temperature must be between 0.0 and 2.0")
                }
            }

            if let topP = topP {
                guard topP >= 0.0 && topP <= 1.0 else {
                    throw ValidationError("Top-p must be between 0.0 and 1.0")
                }
            }

            if let maxTokens = maxTokens {
                guard maxTokens > 0 else {
                    throw ValidationError("Max tokens must be positive")
                }
            }

            if let adapterPath = load {
                guard FileManager.default.fileExists(atPath: adapterPath) else {
                    throw ValidationError("Adapter file not found: \(adapterPath)")
                }
                guard adapterPath.hasSuffix(".fmadapter") else {
                    throw ValidationError("Adapter file must have .fmadapter extension")
                }
            }
        }

        func run() throws {
            let group = DispatchGroup()
            group.enter()

            Task {
                do {
                    let chat = ChatSession(
                        settings: .init(
                            system: system,
                            history: noHistory ? false : true,  // Default true unless --no-history
                            wordwrap: noWordwrap ? false : true,  // Default true unless --no-wordwrap
                            format: format,
                            verbose: verbose
                        ),
                        parameters: .init(
                            seed: seed,
                            temperature: temperature,
                            topP: topP,
                            maxTokens: maxTokens,
                            stop: stop
                        ),
                        adapterPath: load
                    )
                    try await chat.start(with: model)
                } catch {
                    print("Chat error: \(error)")
                }
                group.leave()
            }

            group.wait()
        }
    }
}

// MARK: -

private final actor ChatSession {
    enum Command: String, CaseIterable {
        case help = "help"
        case questionMark = "?"
        case set = "set"
        case show = "show"
        case clear = "clear"
        case bye = "bye"

        var helpText: String {
            switch self {
            case .help, .questionMark: return "Show help information"
            case .set: return "Set session variables"
            case .show: return "Show current settings and parameters"
            case .clear: return "Clear session context and history"
            case .bye: return "Exit the chat session"
            }
        }
    }

    struct SetCommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set",
            abstract: "Set session variables",
            subcommands: [
                SetParameter.self, SetSystem.self, SetHistory.self, SetWordwrap.self,
                SetFormat.self, SetVerbose.self,
            ]
        )

        struct SetParameter: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "parameter",
                abstract: "Set generation parameters"
            )

            @Argument(help: "Parameter name (seed, temperature, top-p, max-tokens, stop)")
            var name: String

            @Argument(help: "Parameter value")
            var value: String
        }

        struct SetSystem: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "system",
                abstract: "Set system message"
            )

            @Argument(help: "System message text")
            var message: String
        }

        struct SetHistory: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "history",
                abstract: "Enable or disable history"
            )

            @Flag(help: "Enable history")
            var enable: Bool = false

            @Flag(help: "Disable history")
            var disable: Bool = false
        }

        struct SetWordwrap: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "wordwrap",
                abstract: "Enable or disable word wrapping"
            )

            @Flag(help: "Enable wordwrap")
            var enable: Bool = false

            @Flag(help: "Disable wordwrap")
            var disable: Bool = false
        }

        struct SetFormat: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "format",
                abstract: "Set output formatting"
            )

            @Argument(help: "Format type (json)")
            var type: String?
        }

        struct SetVerbose: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "verbose",
                abstract: "Enable or disable verbose output"
            )

            @Flag(help: "Enable verbose mode")
            var enable: Bool = false

            @Flag(help: "Disable verbose mode (quiet)")
            var disable: Bool = false
        }
    }

    @Dependency(\.foundationModelsClient) var foundationModelsClient

    struct Settings {
        var system: String = ""
        var history: Bool = true
        var wordwrap: Bool = true
        var format: Bool = false
        var verbose: Bool = false
    }

    private let historyFile = "\(NSHomeDirectory())/.olleh_history"

    var settings: Settings

    var parameters: FoundationModelsDependency.Parameters
    let adapterPath: String?

    init(
        settings: Settings = .init(),
        parameters: FoundationModelsDependency.Parameters = .init(),
        adapterPath: String? = nil
    ) {
        self.settings = settings
        self.parameters = parameters
        self.adapterPath = adapterPath
    }

    func start(with model: String) async throws {
        if foundationModelsClient.isAvailable() {
            // Load adapter if specified
            if let adapterPath = adapterPath {
                try foundationModelsClient.loadAdapter(adapterPath)
                if settings.verbose {
                    print("Loaded adapter from: \(adapterPath)")
                }
            }

            _ = await withLoadingAnimation {
                await self.foundationModelsClient.prewarm()
            }
        }

        if settings.history {
            Bestline.loadHistory(from: historyFile)
        }

        Bestline.setHintsCallback { input in
            if input.isEmpty {
                return "Enter a message (/? for help)"
            }
            return ""
        }

        Bestline.setCompletionCallback { input, _ in
            if input.hasPrefix("/") {
                let commands = Command.allCases.map { "/\($0.rawValue)" }
                return commands.filter { $0.hasPrefix(input) }
            } else if input.hasPrefix("/set ") {
                let settingNames = [
                    "parameter", "system", "history", "wordwrap", "format", "verbose",
                ]
                let setPrefix = "/set "
                return settingNames.compactMap { name in
                    let fullCommand = setPrefix + name
                    return fullCommand.hasPrefix(input) ? fullCommand : nil
                }
            } else if input.hasPrefix("/set parameter ") {
                let paramNames = ["seed", "temperature", "top-p", "max-tokens", "stop"]
                let paramPrefix = "/set parameter "
                return paramNames.compactMap { param in
                    let fullCommand = paramPrefix + param
                    return fullCommand.hasPrefix(input) ? fullCommand : nil
                }
            }
            return []
        }

        Bestline.setMultilineMode(true)

        while true {
            let input: String?
            if settings.history {
                input = Bestline.readLineWithHistory(
                    prompt: ">>> ", historyFile: historyFile)
            } else {
                input = Bestline.readLine(prompt: ">>> ")
            }

            guard let input = input else {
                break
            }

            // Handle empty input
            if input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }

            // Handle commands
            if input.hasPrefix("/") {
                await handleCommand(input, model: model)
                continue
            }

            // Handle regular chat
            do {
                // Add to history for persistence
                if settings.history {
                    Bestline.addToHistory(input)
                }

                if foundationModelsClient.isAvailable() {
                    let finalPrompt =
                        settings.system.isEmpty
                        ? input : "\(settings.system)\n\nUser: \(input)"

                    do {
                        let streamedContent = try await foundationModelsClient.streamGenerate(
                            model, finalPrompt, parameters)

                        print("", terminator: "")  // Start on new line
                        var totalResponse = ""
                        var isFirstChunk = true

                        for try await chunk in streamedContent {
                            if isFirstChunk {
                                // Clear any potential spinner or formatting from connection phase
                                print("\r\u{001B}[K", terminator: "")
                                isFirstChunk = false
                            }
                            print(chunk, terminator: "")
                            fflush(stdout)
                            totalResponse += chunk
                        }

                        print()  // End with newline

                        if settings.verbose {
                            print(
                                "\n[Verbose: Message processed - \(totalResponse.count) characters]"
                            )
                        }
                    } catch {
                        // Fallback to non-streaming if streaming fails
                        let response = try await withLoadingAnimation {
                            try await self.foundationModelsClient.generate(
                                model, finalPrompt,
                                self.parameters)
                        }

                        print(response)

                        if settings.verbose {
                            print("\n[Verbose: Message processed (fallback)]")
                        }
                    }
                } else {
                    print("Foundation Models not available on this system")
                }
                print()
            } catch {
                print("Error: \(error)")
                print()
            }
        }
    }

    private func handleCommand(_ command: String, model: String) async {
        let (parsedCommand, args) = parseCommand(command)

        guard let parsedCommand = parsedCommand else {
            print("Unknown command: \(command)")
            print("Type '/?' for help")
            return
        }

        switch parsedCommand {
        case .questionMark, .help:
            if args.first == "set" {
                showSetHelp()
            } else if args.first == "shortcuts" {
                showKeyboardShortcuts()
            } else {
                showHelp()
            }
        case .set:
            handleSetCommand(args.joined(separator: " "))
        case .show:
            await handleShowCommand(model: model)
        case .clear:
            handleClearCommand()
        case .bye:
            handleByeCommand()
        }
        print()
    }

    private func handleSetCommand(_ args: String) {
        let parts = args.split(separator: " ", maxSplits: 1).map(String.init)

        if parts.isEmpty {
            showSetHelp()
            return
        }

        let settingName = parts[0].lowercased()
        let value = parts.count > 1 ? parts[1] : ""

        switch settingName {
        case "parameter":
            if value.isEmpty {
                showParameterHelp()
            } else {
                handleParameterSet(value)
            }
        case "system":
            settings.system = value
            print("System message set to: \(value)")
        case "history":
            settings.history = true
            print("History enabled")
        case "nohistory":
            settings.history = false
            print("History disabled")
        case "wordwrap":
            settings.wordwrap = true
            print("Wordwrap enabled")
        case "nowordwrap":
            settings.wordwrap = false
            print("Wordwrap disabled")
        case "format":
            if value.lowercased() == "json" {
                settings.format = true
                print("JSON mode enabled")
            }
        case "noformat":
            settings.format = false
            print("Formatting disabled")
        case "verbose":
            settings.verbose = true
            print("Verbose mode enabled")
        case "quiet":
            settings.verbose = false
            print("Quiet mode enabled")
        default:
            print("Unknown setting: \(settingName)")
        }
    }

    private func handleParameterSet(_ args: String) {
        let parts = args.split(separator: " ", maxSplits: 1).map(String.init)
        if parts.count < 2 {
            print("Usage: /set parameter <name> <value>")
            return
        }

        let paramName = parts[0].lowercased()
        let paramValue = parts[1]

        switch paramName {
        case "seed":
            if let seedValue = Int(paramValue) {
                parameters.seed = seedValue
                print("Seed set to: \(seedValue)")
            } else {
                print("Invalid seed value. Must be an integer.")
            }
        case "temperature":
            if let tempValue = Double(paramValue), tempValue >= 0.0 && tempValue <= 2.0 {
                parameters.temperature = tempValue
                print("Temperature set to: \(tempValue)")
            } else {
                print("Invalid temperature value. Must be between 0.0 and 2.0.")
            }
        case "top-p":
            if let topPValue = Double(paramValue), topPValue >= 0.0 && topPValue <= 1.0 {
                parameters.topP = topPValue
                print("Top-p set to: \(topPValue)")
            } else {
                print("Invalid top_p value. Must be between 0.0 and 1.0.")
            }
        case "max-tokens":
            if let maxTokens = Int(paramValue), maxTokens > 0 {
                parameters.maxTokens = maxTokens
                print("Max tokens set to: \(maxTokens)")
            } else {
                print("Invalid max_tokens value. Must be a positive integer.")
            }
        case "stop":
            parameters.stop = paramValue
            print("Stop sequence set to: \(paramValue)")
        default:
            print("Unknown parameter: \(paramName)")
            showParameterHelp()
        }
    }

    private func handleShowCommand(model: String) async {
        print("Current Configuration:")
        print("  Model: \(model)")
        print()

        print("Settings:")
        print(
            "  System message: \(settings.system.isEmpty ? "(none)" : "\"\(settings.system)\"")"
        )
        print("  History: \(settings.history ? "enabled" : "disabled")")
        print("  Wordwrap: \(settings.wordwrap ? "enabled" : "disabled")")
        print("  Format: \(settings.format ? "json" : "text")")
        print("  Verbose: \(settings.verbose ? "enabled" : "disabled")")

        let params = parameters.dictionaryValue
        if !params.isEmpty {
            print()
            print("Generation Parameters:")
            for (key, value) in params.sorted(by: { $0.key < $1.key }) {
                print("  \(key): \(value)")
            }
        } else {
            print()
            print("Generation Parameters: (using defaults)")
        }
    }

    private func handleClearCommand() {
        Bestline.freeHistory()
        parameters = .init()
        settings.system = ""
        print("Session context and history cleared")
    }

    private func handleByeCommand() {
        print("Bye! Have a great day!")
        if settings.history {
            Bestline.saveHistory(to: historyFile)
        }
        exit(0)
    }

    private func parseCommand(_ input: String) -> (command: Command?, args: [String]) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return (nil, []) }

        let withoutSlash = String(trimmed.dropFirst())
        let parts = withoutSlash.split(separator: " ", omittingEmptySubsequences: true)
            .map(
                String.init)

        guard let firstPart = parts.first,
            let command = Command(rawValue: firstPart)
        else {
            return (nil, parts)
        }

        return (command, Array(parts.dropFirst()))
    }

    private func showHelp() {
        print("Available Commands:")
        for command in Command.allCases {
            let commandStr = "/\(command.rawValue)"
            let padding = String(repeating: " ", count: max(0, 15 - commandStr.count))
            print("  \(commandStr)\(padding)\(command.helpText)")
        }
        print()
        print("For detailed help on setting values, use: /help set")
        print()
        print("Multi-line input:")
        print("  Use \"\"\" to begin a multi-line message and \"\"\" to end it.")
        print()
        print("History and completion:")
        print("  Use Up/Down arrows to navigate command history.")
        print("  Use Tab to auto-complete commands.")
    }

    private func showSetHelp() {
        print("Available Settings:")
        print("  /set parameter ...     Set a parameter")
        print("  /set system <string>   Set system message")
        print("  /set history           Enable history")
        print("  /set nohistory         Disable history")
        print("  /set wordwrap          Enable wordwrap")
        print("  /set nowordwrap        Disable wordwrap")
        print("  /set format json       Enable JSON mode")
        print("  /set noformat          Disable formatting")
        print("  /set verbose           Show LLM stats")
        print("  /set quiet             Disable LLM stats")
    }

    private func showParameterHelp() {
        print("Available Parameters:")
        print("  /set parameter seed <int>           Random number seed")
        print("  /set parameter temperature <float>  Sampling temperature (0.0-2.0)")
        print(
            "  /set parameter top-p <float>        Nucleus sampling probability (0.0-1.0)"
        )
        print("  /set parameter max-tokens <int>     Maximum tokens to generate")
        print("  /set parameter stop <string>        Stop sequences")
    }

    private func showKeyboardShortcuts() {
        print("Keyboard shortcuts:")
        print("  Ctrl+C          Interrupt current operation")
        print("  Ctrl+D          Exit (EOF)")
        print("  Up/Down arrows  Navigate command history")
        print("  Tab             Auto-complete commands")
        print("  Ctrl+A          Move to beginning of line")
        print("  Ctrl+E          Move to end of line")
        print("  Ctrl+L          Clear screen")
        print("  \"\"\"           Begin multi-line message")
    }
}

extension FoundationModelsDependency.Parameters {
    fileprivate var dictionaryValue: [String: Ollama.Value] {
        var dict: [String: Ollama.Value] = [:]
        if let seed = seed {
            dict["seed"] = .int(seed)
        }
        if let temperature = temperature {
            dict["temperature"] = .double(temperature)
        }
        if let topP = topP {
            dict["top_p"] = .double(topP)
        }
        if let maxTokens = maxTokens {
            dict["max_tokens"] = .int(maxTokens)
        }
        if let stop = stop {
            dict["stop"] = .string(stop)
        }
        return dict
    }
}
