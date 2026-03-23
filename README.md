# CameraSession SDK

A lightweight iOS camera capture SDK that delivers raw `CVPixelBuffer` frames through a delegate protocol. Built for integration into computer vision and AR pipelines where direct pixel buffer access is needed instead of a preview layer.

## Features

- **Enum-based state machine** for thread-safe session lifecycle (`idle → configured → running → stopping → configured`)
- **Manual format resolution** — bypasses `AVCaptureSession` presets for deterministic control over resolution, FPS, and frame duration
- **Deadlock-free threading** — all internal dispatch is async; safe to call `stop()` from within the delegate callback
- **C-callable shim** (`CameraShim.h`) for integration with C/C++ codebases (AR engines, game engines, FFI bridges)
- **Configurable delegate queue** — receive frames on main or any custom dispatch queue
- **os_signpost instrumentation** for profiling `configure()` in Instruments

## Requirements

- iOS 15.0+
- Swift 5.9+
- Xcode 15+

## Installation

Add via Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/suyashbitspilani/ios-camera-sdk-suyash.git", branch: "main")
]
```

## Quick Start

```swift
import CameraSession

class FrameProcessor: CameraSessionDelegate {
    let session = CameraSession(delegateQueue: .main)

    func startCapture() throws {
        session.delegate = self
        try session.configure(resolution: .hd1920x1080, fps: 30)
        session.start()
    }

    func cameraSession(_ session: CameraSession,
                       didOutputPixelBuffer buffer: CVPixelBuffer,
                       timestamp: CMTime) {
        // Process the pixel buffer here
    }
}
```

## Architecture

```
Caller (any queue)
    ├─ configure() ──sync──▶ runs on caller's queue (validation + device setup)
    ├─ start()  ──async──▶ sessionQueue (private serial, .userInitiated)
    │                         └──async──▶ delegateQueue (user-provided or .main)
    └─ stop()   ──async──▶ sessionQueue
```

- `sessionQueue` — private serial queue that owns the `AVCaptureSession` and all state transitions
- `delegateQueue` — user-provided queue (defaults to `.main`) where `didOutputPixelBuffer` fires
- `FormatResolver` — isolated struct that matches device formats to requested resolution + FPS

## C Interface

```c
#include "CameraShim.h"

int camera_configure(const char* resolution_preset, int fps);
int camera_start(void);
void camera_stop(void);
```

Pure C types only (`int`, `void`, `const char*`) — compiles from `.c`, `.m`, `.cpp`, and `.mm` files without Objective-C bridging headers.

## Tests

| Test | Description | Runs on Simulator |
|------|-------------|-------------------|
| `testConfigureThrowsForUnsupportedFormat` | Verifies SDK throws typed error for impossible format (1080p @ 240fps) | Yes |
| `testDelegateFiresOnCustomQueue` | Validates delegate callback fires on the queue passed to `init()` | Requires real device |

```bash
# Run tests via command line
xcodebuild test -scheme CameraSession -destination 'platform=iOS Simulator,name=iPhone 15'
```

## Project Structure

```
Sources/
├── CameraSession/
│   ├── CameraSession.swift          # Main session class with state machine
│   ├── CameraSessionDelegate.swift  # Delegate protocol
│   ├── CameraSessionError.swift     # Typed errors
│   └── FormatResolver.swift         # Format matching logic
└── CameraSessionObjC/
    ├── include/CameraShim.h         # C-callable header
    └── CameraShim.m                 # ObjC implementation

Tests/CameraSessionTests/
└── CameraSessionTests.swift

SampleApp/                           # Demo app with pixel buffer rendering
```

## Design Notes

See [NOTES.md](NOTES.md) for detailed discussion of:
- State machine vs boolean flags
- Async dispatch for deadlock prevention
- `sessionPreset = .inputPriority` rationale
- Singleton C shim trade-offs and opaque handle alternative
- `dispatchPrecondition` vs `Thread.isMainThread`
- Memory management (`weak delegate`, `[weak self]`, `deinit` teardown)
