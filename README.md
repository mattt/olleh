<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Assets/logo-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="Assets/logo-light.svg">
  <img alt="olleh" width="200">
</picture>

![Screen recording of olleh command running interactively](/demo.gif)

Olleh provides an Ollama-compatible API to Apple's new
[Foundation Models](https://developer.apple.com/documentation/foundationmodels),
announced at WWDC 2025.
It serves as a bridge between Apple's native AI capabilities and the
Ollama ecosystem, offering both a command-line interface and an HTTP API
for seamless integration with existing tools and workflows.

## Requirements

- macOS 26 beta or later
- Apple Silicon Mac (M1 or later)
- Xcode 26 beta / Swift 6.2+

## Installation

### Homebrew

```bash
brew install loopwork/tap/olleh
```

### Building from Source

```bash
git clone https://github.com/loopwork/olleh.git
cd olleh
make
sudo make install # installs to /usr/local/bin/
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
  show                    Show model information
  check                   Check availability

  See 'olleh help <subcommand>' for detailed help.
```

### Command Details

#### `olleh serve`

Start the [Ollama-compatible HTTP API](https://github.com/ollama/ollama/blob/main/docs/api.md) server.

```bash
# Default configuration (port 11941)
olleh serve

# Verbose logging
olleh serve --verbose

# Bind to specific host and port
olleh serve --host 0.0.0.0 --port 11434 # default ollama port 
```

#### `olleh run`

Start an interactive chat session with the model.

```bash
$ olleh run default
>>> Enter a message (/? for help)
```

Use `Ctrl+C` or type `/bye` to exit the chat session.

#### `olleh list`

List all available models.
Currently returns only the `default` Foundation Model.

```console
$ olleh list
NAME                     ID             SIZE     MODIFIED
default                                 N/A      2 weeks ago
```

#### `olleh show`

Show information about a model.

```console
$ olleh show default
  Model
    architecture        foundation
    parameters          3B
    context length      65536
    embedding length    2048
    quantization        2b-qat

  Capabilities
    completion
    tools

  Parameters
    temperature    0.7

  License
    Apple Terms of Use
```

#### `olleh check`

Verify that Foundation Models are available on your system.

```console
$ olleh check
Foundation Models available
```

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
# Generate text with streaming
curl http://localhost:11941/api/generate -d '{
  "model": "default",
  "prompt": "Why is the sky blue?",
  "stream": true
}'

# Chat completion
curl http://localhost:11941/api/chat -d '{
  "model": "default",
  "messages": [
    {"role": "user", "content": "Hello, how are you?"}
  ],
}'
```

## Model Support

Olleh currently supports the lone `default` model
provided by Apple's Foundation Models framework.

### Foundation Models Adapters

Olleh supports loading custom Foundation Models adapters using the `--adapter` flag:

```bash
# Load and run with a custom adapter
olleh run default --adapter /path/to/my_adapter.fmadapter
```

Foundation Models adapters let you:

- Specialize the model for specific domains or tasks
- Improve accuracy and consistency for your use case
- Add new skills to the base model

See [Apple's Foundation Models Adapter documentation](https://developer.apple.com/apple-intelligence/foundation-models-adapter/)
for information on training custom adapters.

### Future Features

Future releases may include:
- Support for specialized models as they become available
- Model configuration and fine-tuning options
- Adapter management commands

## License

This project is available under the MIT license.
See the LICENSE file for more info.
