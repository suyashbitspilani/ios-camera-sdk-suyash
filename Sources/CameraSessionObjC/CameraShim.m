#import "CameraShim.h"
@import AVFoundation;

// We can't directly import the Swift module here because CameraSessionObjC
// is a dependency of CameraSession (not the other way around). The shim
// provides the C interface; the actual bridging to the Swift CameraSession
// class happens at the app level or via a thin wrapper target.
//
// For now, this implementation provides the C entry points with stubbed
// internals. In a full integration, you would either:
//   1. Create a separate bridging target that depends on both CameraSession
//      and CameraSessionObjC, or
//   2. Use the Objective-C runtime (NSClassFromString + performSelector) to
//      call into the Swift class without a compile-time dependency.

static AVCaptureSession *_sharedSession = nil;

int camera_configure(const char* resolution_preset, int fps) {
    if (resolution_preset == NULL) {
        return -1;
    }

    @synchronized ([AVCaptureSession class]) {
        if (_sharedSession == nil) {
            _sharedSession = [[AVCaptureSession alloc] init];
        }

        NSString *presetString = [NSString stringWithUTF8String:resolution_preset];

        // Map string to AVCaptureSessionPreset
        AVCaptureSessionPreset preset;
        if ([presetString isEqualToString:@"hd1920x1080"]) {
            preset = AVCaptureSessionPreset1920x1080;
        } else if ([presetString isEqualToString:@"hd1280x720"]) {
            preset = AVCaptureSessionPreset1280x720;
        } else if ([presetString isEqualToString:@"vga640x480"]) {
            preset = AVCaptureSessionPreset640x480;
        } else if ([presetString isEqualToString:@"hd4K3840x2160"]) {
            preset = AVCaptureSessionPreset3840x2160;
        } else {
            return -1;  // Unknown preset
        }

        if (![_sharedSession canSetSessionPreset:preset]) {
            return -2;  // Unsupported on this device
        }

        [_sharedSession setSessionPreset:preset];
    }

    return 0;
}

int camera_start(void) {
    @synchronized ([AVCaptureSession class]) {
        if (_sharedSession == nil) {
            return -1;  // Not configured
        }
        [_sharedSession startRunning];
    }
    return 0;
}

void camera_stop(void) {
    @synchronized ([AVCaptureSession class]) {
        if (_sharedSession != nil) {
            [_sharedSession stopRunning];
        }
    }
}
