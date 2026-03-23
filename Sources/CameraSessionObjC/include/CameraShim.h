#ifndef CameraShim_h
#define CameraShim_h

#ifdef __cplusplus
extern "C" {
#endif

int camera_start(void);
void camera_stop(void);

#ifdef __cplusplus
}
#endif

#endif /* CameraShim_h */
