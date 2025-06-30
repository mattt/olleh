# olleh

![Screen recording of olleh command running interactively](/demo.gif)

Olleh provides an Ollama-compatible API to Apple's new
[Foundation Models](https://developer.apple.com/documentation/foundationmodels),
announced at WWDC 2025.
It serves as a bridge between Apple's native AI capabilities and the
Ollama ecosystem, offering both a command-line interface and an HTTP API
for seamless integration with existing tools and workflows.

## Requirements

- macOS 26 beta or later
- Xcode 26 beta / Swift 6.2+
- Apple Silicon Mac (M1 or later)

## Installation

### Building from Source

```bash
git clone https://github.com/loopwork/olleh.git
cd olleh
swift build -c release
```

To install the built executable to your `PATH`:

```bash
swift build -c release
cp .build/release/olleh /usr/local/bin/
```

## Quick Start

```bash
# Check if Foundation Models are available
olleh check

# Start the Ollama-compatible API server
olleh serve

# Chat interactively with the model
olleh run default
```

## CLI Reference

### Available Commands

```terminal
❯ olleh
OVERVIEW: Ollama-compatible CLI for Apple Foundation Models

USAGE: olleh <subcommand>

OPTIONS:
  --version               Show the version.
  -h, --help              Show help information.

SUBCOMMANDS:
  serve                   Start olleh
  run                     Run a model interactively
  list                    List models
  check                   Check availability

  See 'olleh help <subcommand>' for detailed help.
```

### Command Details

#### `olleh serve`

Start the [Ollama-compatible HTTP API](https://github.com/ollama/ollama/blob/main/docs/api.md) server.

```bash
# Default configuration (port 11941)
olleh serve

# Custom port
olleh serve --port 8080

# Verbose logging
olleh serve --verbose

# Bind to specific host
olleh serve --host 0.0.0.0 --port 8080
```

#### `olleh run`

Start an interactive chat session with the model.

```bash
olleh run default
```

Use `Ctrl+C` or type `/bye` to exit the chat session.

#### `olleh check`

Verify that Foundation Models are available on your system.

#### `olleh list`

List all available models.
Currently returns only the `default` Foundation Model.

## HTTP API

When running `olleh serve`,
the following Ollama-compatible endpoints are available:

- `POST /api/generate` - Generate text completions
- `POST /api/chat` - Chat with the model
- `GET /api/tags` - List available models
- `GET /api/show` - Show information about a model

### Example: Using with Ollama Swift Client

You can use Olleh with the
[Ollama Swift](https://github.com/loopwork/ollama-swift)
client library:

```swift
import Ollama

// Connect to olleh server (default port: 11941)
let client = Client(host: URL("http://localhost:11941")!)

// Generate text using Apple's Foundation Models
let response = try await client.generate(
    model: "default",
    prompt: "Tell me about Swift programming.",
    options: [
        "temperature": 0.7,
        "max_tokens": 100
    ]
)
print(response.response)
```

### Example: Using with curl

```bash
# Generate text
curl http://localhost:11941/api/generate -d '{
  "model": "default",
  "prompt": "Why is the sky blue?"
}'

# Chat completion
curl http://localhost:11941/api/chat -d '{
  "model": "default",
  "messages": [
    {"role": "user", "content": "Hello, how are you?"}
  ]
}'
```

## Model Support

Olleh currently supports the lone `default` model
provided by Apple's Foundation Models framework.

Future releases may include:
- Support for specialized models as they become available
- Integration with [custom adapters](https://developer.apple.com/apple-intelligence/foundation-models-adapter/)
- Model configuration and fine-tuning options

## Troubleshooting

### Common Issues

**Foundation Models not available**
- Ensure you're running macOS 26 beta or later
- Verify you have an Apple Silicon Mac
- Check that Foundation Models framework is properly installed

**Server fails to start**
- Check if another process is using the port
- Try a different port with `--port` flag
- Ensure you have necessary permissions

**Model responses are slow**
- Foundation Models require significant computational resources
- Ensure other resource-intensive applications are closed
- Consider adjusting generation parameters for faster responses

## License

This project is licensed under the Apache License, Version 2.0.
