# CameraSession SDK — Design Notes

## 1. Design Decisions

### State Machine over Booleans

The first instinct when managing session lifecycle is a couple of boolean flags — `isRunning`, `isConfigured`. This falls apart quickly. When `start()` and `stop()` can be called from arbitrary queues (including from inside the delegate callback), you end up with race conditions where `isRunning` reads as `true` on one queue while another queue is halfway through tearing down the session.

An enum-based state machine (`idle → configured → running → stopping → configured`) gives us a single source of truth. All transitions happen on `sessionQueue`, so there's no ambiguity. If someone calls `start()` twice, the second call sees `state == .running` and bails out with a log message instead of double-starting the AVCaptureSession (which causes undefined behavior).

The states are:
- **idle**: Fresh instance, nothing configured yet
- **configured**: Device and format are set up, ready to run
- **running**: AVCaptureSession is actively capturing
- **stopping**: Transitional state while `stopRunning()` executes

### Async Dispatch over Sync

Every dispatch to `sessionQueue` uses `.async`, never `.sync`. This is a deliberate choice to prevent a specific deadlock scenario:

1. `sessionQueue` processes an AVCaptureOutput callback
2. That callback dispatches to `delegateQueue` to fire the delegate method
3. The user calls `session.stop()` from inside the delegate callback
4. If `stop()` did `sessionQueue.sync { ... }`, it would block waiting for `sessionQueue`
5. But `sessionQueue` is blocked waiting for the output callback to return
6. Deadlock.

The trade-off: `start()` and `stop()` become fire-and-forget. The caller doesn't know exactly when the session starts or stops. In a future API revision, I'd add completion handlers (`start(completion:)`, `stop(completion:)`) to give callers deterministic lifecycle feedback without sacrificing deadlock safety.

### Separate FormatResolver

Format resolution logic is isolated into its own struct for two reasons:
1. **Testability** — you can unit test the preset-to-dimensions mapping and format filtering without standing up a full AVCaptureSession
2. **Single responsibility** — `CameraSession` orchestrates the pipeline; `FormatResolver` handles the hardware capability query

If the SDK grows to support multi-camera or front/back switching, `FormatResolver` becomes the natural place to add device-specific scoring heuristics without bloating the main class.

### `session.sessionPreset = .inputPriority`

Apple's session presets (`.hd1920x1080`, etc.) are hardware "suggestions" — they let the system pick a format it thinks is best. For AR and computer vision pipelines, this isn't good enough. You need deterministic control over the exact format to guarantee consistent frame dimensions, exposure duration, and motion blur characteristics that your CV algorithms depend on.

Setting `.inputPriority` tells AVFoundation: "I'm manually managing `activeFormat` and frame duration — don't override my choices." This is what ARKit does internally, and it's the right approach for any pipeline that processes raw pixel data.

## 2. Threading Model

```
Caller (any queue)
    │
    ├─ configure() ──sync──▶ runs on caller's queue (validation + device setup)
    │                         no queue hop needed — this is a synchronous throws API
    │
    ├─ start() ──async──▶ sessionQueue (private serial, .userInitiated QoS)
    │                         │ owns AVCaptureSession
    │                         │ AVCaptureVideoDataOutput callback fires here
    │                         │
    │                         └──async──▶ delegateQueue (user-provided or .main)
    │                                       │ didOutputPixelBuffer fires here
    │                                       │ user may call stop() here — safe
    │                                       │ because stop() dispatches async
    │
    └─ stop() ──async──▶ sessionQueue
                            │ stopRunning() is synchronous on sessionQueue
                            │ state transitions to .configured
```

Key insight: the `delegateQueue` is always a *different* queue from `sessionQueue`. The AVCaptureOutput callback fires on `sessionQueue`, extracts the pixel buffer, then dispatches async to `delegateQueue` for delivery. This separation is what makes it safe to call `stop()` from the delegate callback.

## 3. Format Selection Strategy

The `FormatResolver` works in three steps:

1. **Map preset to dimensions**: `AVCaptureSession.Preset` doesn't expose its target resolution, so we maintain a lookup table (`.hd1920x1080` → 1920×1080, `.hd1280x720` → 1280×720, etc.)

2. **Filter by resolution**: Iterate `AVCaptureDevice.formats`, compare each format's `CMVideoDimensions` against the target. A device might have dozens of formats for the same resolution (different color spaces, binning modes, HDR support).

3. **Check FPS support**: For each resolution match, scan `videoSupportedFrameRateRanges`. The requested FPS must fall within `minFrameRate...maxFrameRate` for at least one range.

We take the first match. A more sophisticated implementation would score candidates by preferring:
- Formats with wider dynamic range
- Binned modes (lower power consumption) over full-readout
- Formats that support the camera's native color space

On failure, the error includes both the requested config and a list of everything the device actually supports, so the caller can make an informed fallback choice.

## 4. C Shim Trade-offs

The C shim (`CameraShim.h` / `.m`) exposes a singleton interface:

```c
int camera_configure(const char* resolution_preset, int fps);
int camera_start(void);
void camera_stop(void);
```

**Why pure C types**: The header uses `int`, `void`, and `const char*` — no `BOOL`, `NSString`, or Objective-C class references. This guarantees clean compilation from `.c`, `.m`, `.cpp`, and `.mm` translation units. An AR engine written in C++ can `#include "CameraShim.h"` without any Objective-C bridging headers.

**Singleton limitations**:
- Can't manage multiple cameras simultaneously (front + back for depth)
- No per-session configuration — one caller's `camera_configure()` affects everyone
- No lifecycle isolation — `camera_stop()` kills the session for all consumers
- Thread safety relies on `@synchronized`, adding contention under heavy use

**Better pattern for production**: Opaque handles.
```c
typedef struct CameraHandle* camera_handle_t;
camera_handle_t camera_create(const char* preset, int fps);
int camera_start(camera_handle_t handle);
void camera_stop(camera_handle_t handle);
void camera_destroy(camera_handle_t handle);
```
Each handle wraps an independent `CameraSession` instance. Callers manage their own lifecycle. No shared state.

**When the singleton is fine**: Single-camera AR prototyping, thin FFI bridges where you know there's exactly one consumer, embedded use cases with a fixed camera pipeline.

## 5. `dispatchPrecondition` vs `Thread.isMainThread`

`Thread.isMainThread` checks physical thread identity — whether your code happens to be running on thread #1. But GCD doesn't guarantee a 1:1 mapping between queues and threads. Main queue work can execute on a non-main thread during `sync` dispatch from the main queue, and background queue work can end up on the main thread if GCD optimizes away the thread hop. `dispatchPrecondition(condition: .onQueue(q))` checks *logical queue ownership* — whether the current execution context is semantically "on" queue `q`, regardless of which physical thread GCD chose. For verifying delegate queue affinity, this is the correct check. We care about which queue owns the execution (because that determines serialization guarantees and reentrancy behavior), not which thread the kernel scheduled it on.

## 6. Memory Management

Three mechanisms prevent leaks and ensure clean teardown:

- **Weak delegate**: `public weak var delegate: CameraSessionDelegate?` prevents the SDK from retaining the host app's view controller or view model. Without this, you get a retain cycle: `ViewController → CameraSession → delegate → ViewController`.

- **`[weak self]` in callbacks**: The AVCaptureVideoDataOutput sample buffer delegate callback captures `self`. If we used a strong reference, the output would retain the session, which retains the output — circular. `[weak self]` with `guard let self` at the top breaks the cycle.

- **`deinit` teardown**: When a `CameraSession` is deallocated, `deinit` calls `stopRunning()`, removes all inputs and outputs, and unregisters notification observers. This is critical for an SDK — if a consumer forgets to call `stop()`, we still release the camera hardware. Leaving the camera "on" after dealloc drains battery, shows the green indicator dot, and blocks other apps from accessing the camera.

## 7. What I'd Add With More Time

- **Completion handlers on start()/stop()**: `start(completion: @escaping () -> Void)` so callers know exactly when capture begins. The async fire-and-forget pattern is deadlock-safe but leaves callers guessing about timing.

- **Frame dropping / backpressure policy**: Right now we set `alwaysDiscardsLateVideoFrames = true`, which drops frames when the consumer is slow. A configurable policy (drop-latest, queue up to N, apply back-pressure) would let CV pipelines make their own trade-offs.

- **Orientation handling**: Device rotation should update either the video connection's `videoOrientation` or rotate pixel buffers post-capture. Without this, frames come in with the wrong orientation after rotation.

- **Privacy permission flow**: `AVCaptureDevice.requestAccess(for: .video)` with proper error states. Currently the SDK assumes permission is already granted — the sample app handles it, but the SDK itself should have a clean permission API.

- **Configurable pixel format**: The SDK hardcodes `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange` (420f), which is efficient for Core Video and Vision pipelines. But Metal rendering and some image processing tasks prefer `kCVPixelFormatType_32BGRA`. A `pixelFormat` parameter on `configure()` would cover both.

- **Multi-camera support**: `AVCaptureMultiCamSession` (iOS 13+) enables simultaneous front + back capture. The current single-device architecture would need significant rework.

- **Thread sanitizer CI**: Run tests with `-fsanitize=thread` in CI to catch any data races that slip through the state machine. The current design should be clean, but TSAN would prove it.

- **Full os_signpost integration**: Beyond the `configure()` timing signpost, instrument the entire frame pipeline — capture callback entry/exit, delegate dispatch latency, frame drop events — so engineers can profile the SDK in Instruments.
