#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct {
    UInt32 callbackCount;
    Float32 maximumInputPeak;
    Float64 phase;
} LoopbackContext;

static OSStatus loopbackIOProc(
    AudioObjectID device,
    const AudioTimeStamp *now,
    const AudioBufferList *input,
    const AudioTimeStamp *inputTime,
    AudioBufferList *output,
    const AudioTimeStamp *outputTime,
    void *contextPointer
) {
    (void)device;
    (void)now;
    (void)inputTime;
    (void)outputTime;
    LoopbackContext *context = contextPointer;

    if (input) {
        for (UInt32 bufferIndex = 0; bufferIndex < input->mNumberBuffers; ++bufferIndex) {
            const AudioBuffer *buffer = &input->mBuffers[bufferIndex];
            const Float32 *samples = buffer->mData;
            UInt32 sampleCount = buffer->mDataByteSize / sizeof(Float32);
            for (UInt32 sample = 0; samples && sample < sampleCount; ++sample) {
                Float32 peak = fabsf(samples[sample]);
                if (peak > context->maximumInputPeak) {
                    context->maximumInputPeak = peak;
                }
            }
        }
    }

    if (output) {
        for (UInt32 bufferIndex = 0; bufferIndex < output->mNumberBuffers; ++bufferIndex) {
            AudioBuffer *buffer = &output->mBuffers[bufferIndex];
            Float32 *samples = buffer->mData;
            UInt32 sampleCount = buffer->mDataByteSize / sizeof(Float32);
            for (UInt32 sample = 0; samples && sample < sampleCount; ++sample) {
                samples[sample] = 0.25f * sinf((Float32)context->phase);
                context->phase += (2.0 * M_PI * 440.0) / 48000.0;
                if (context->phase >= 2.0 * M_PI) {
                    context->phase -= 2.0 * M_PI;
                }
            }
        }
    }

    ++context->callbackCount;
    return noErr;
}

static AudioDeviceID findDevice(CFStringRef wantedUID) {
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(
            kAudioObjectSystemObject, &address, 0, NULL, &size) != noErr) {
        return kAudioObjectUnknown;
    }

    AudioDeviceID *devices = malloc(size);
    if (!devices) return kAudioObjectUnknown;
    if (AudioObjectGetPropertyData(
            kAudioObjectSystemObject, &address, 0, NULL, &size, devices) != noErr) {
        free(devices);
        return kAudioObjectUnknown;
    }

    AudioDeviceID found = kAudioObjectUnknown;
    UInt32 count = size / sizeof(AudioDeviceID);
    for (UInt32 index = 0; index < count; ++index) {
        CFStringRef uid = NULL;
        UInt32 uidSize = sizeof(uid);
        AudioObjectPropertyAddress uidAddress = {
            kAudioDevicePropertyDeviceUID,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        if (AudioObjectGetPropertyData(
                devices[index], &uidAddress, 0, NULL, &uidSize, &uid) == noErr
                && uid) {
            Boolean matches = CFEqual(uid, wantedUID);
            CFRelease(uid);
            if (matches) {
                found = devices[index];
                break;
            }
        }
    }
    free(devices);
    return found;
}

int main(void) {
    AudioDeviceID device = findDevice(CFSTR("DualSenseBridgeMic_UID"));
    if (device == kAudioObjectUnknown) {
        fprintf(stderr, "DualSense Bridge Mic is not visible to Core Audio\n");
        return 1;
    }

    UInt32 bufferFrames = 480;
    UInt32 size = sizeof(bufferFrames);
    AudioObjectPropertyAddress bufferAddress = {
        kAudioDevicePropertyBufferFrameSize,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    (void)AudioObjectSetPropertyData(
        device, &bufferAddress, 0, NULL, size, &bufferFrames
    );

    LoopbackContext context;
    memset(&context, 0, sizeof(context));
    AudioDeviceIOProcID procID = NULL;
    OSStatus status = AudioDeviceCreateIOProcID(
        device, loopbackIOProc, &context, &procID
    );
    if (status != noErr) {
        fprintf(stderr, "AudioDeviceCreateIOProcID failed: %d\n", status);
        return 2;
    }

    status = AudioDeviceStart(device, procID);
    if (status != noErr) {
        fprintf(stderr, "AudioDeviceStart failed: %d\n", status);
        AudioDeviceDestroyIOProcID(device, procID);
        return 3;
    }
    usleep(750000);
    AudioDeviceStop(device, procID);
    AudioDeviceDestroyIOProcID(device, procID);

    if (context.callbackCount < 5) {
        fprintf(stderr, "HAL delivered only %u IO callbacks\n", context.callbackCount);
        return 4;
    }
    if (context.maximumInputPeak < 0.10f) {
        fprintf(stderr, "HAL loopback stayed silent (peak %.5f)\n", context.maximumInputPeak);
        return 5;
    }

    printf(
        "DualSense Bridge Mic passed loaded-HAL loopback: callbacks=%u peak=%.3f\n",
        context.callbackCount,
        context.maximumInputPeak
    );
    return 0;
}
