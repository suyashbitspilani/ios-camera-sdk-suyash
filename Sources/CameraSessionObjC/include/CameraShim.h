#ifndef CameraShim_h
#define CameraShim_h

/*
 * CameraShim — C-callable interface to CameraSession
 *
 * This header uses only pure C types (no BOOL, NSString, @class, etc.)
 * so it compiles cleanly from both C and C++ translation units.
 *
 * The functions below operate on a single shared CameraSession instance
 * (singleton pattern). This design has significant trade-offs:
 *
 * LIMITATIONS OF THE SINGLETON APPROACH:
 *   - Cannot manage multiple simultaneous cameras (e.g. front + back).
 *   - No per-session configuration — all callers share one config.
 *   - No independent lifecycle control — one caller's stop() affects everyone.
 *   - Concurrent pipelines (depth + color, multi-cam) are impossible.
 *   - Thread safety of the shared instance must be carefully managed by
 *     the implementation; callers have no way to synchronize access.
 *
 * BETTER ALTERNATIVE FOR PRODUCTION:
 *   Use an opaque handle pattern:
 *     typedef struct CameraHandle* camera_handle_t;
 *     camera_handle_t camera_create(const char* preset, int fps);
 *     int  camera_start(camera_handle_t handle);
 *     void camera_stop(camera_handle_t handle);
 *     void camera_destroy(camera_handle_t handle);
 *   This gives each caller independent lifecycle, configuration, and
 *   teardown, and supports concurrent front + back camera sessions.
 *
 * WHEN THE SINGLETON IS ACCEPTABLE:
 *   - Simple single-camera AR apps using only the back camera.
 *   - Prototyping and proof-of-concept integrations.
 *   - C FFI bridges where simplicity matters more than flexibility.
 *   - Embedded use cases with a single known camera pipeline.
 */

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Configures the shared camera session with the given resolution preset
 * and frames per second.
 *
 * resolution_preset: One of "hd1920x1080", "hd1280x720", "vga640x480", etc.
 *                    Maps to AVCaptureSession.Preset values internally.
 * fps:               Target frame rate. Must be supported by the device
 *                    for the chosen resolution.
 *
 * Returns 0 on success, non-zero on failure (e.g. unsupported format).
 */
int camera_configure(const char* resolution_preset, int fps);

/*
 * Starts the shared camera session. Must call camera_configure() first.
 * Returns 0 on success, non-zero if the session is not configured.
 */
int camera_start(void);

/*
 * Stops the shared camera session. Safe to call even if not running.
 */
void camera_stop(void);

#ifdef __cplusplus
}
#endif

#endif /* CameraShim_h */
