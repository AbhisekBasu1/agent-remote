#include <CoreAudio/AudioServerPlugIn.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

void *NullAudio_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID);

int main(void) {
    enum {
        deviceObjectID = 3,
        inputStreamObjectID = 4,
        outputStreamObjectID = 8,
        frameCount = 480
    };

    AudioServerPlugInDriverRef driver = (AudioServerPlugInDriverRef)
        NullAudio_Create(NULL, kAudioServerPlugInTypeUUID);
    if (!driver) {
        fprintf(stderr, "factory did not return a driver\n");
        return 1;
    }

    AudioServerPlugInIOCycleInfo cycle;
    memset(&cycle, 0, sizeof(cycle));
    Float32 source[frameCount * 2];
    Float32 destination[frameCount * 2];
    Float32 underrun[frameCount * 2];
    for (int frame = 0; frame < frameCount; ++frame) {
        source[frame * 2] = (Float32)frame / (Float32)frameCount;
        source[frame * 2 + 1] = -source[frame * 2];
    }
    memset(destination, 0, sizeof(destination));
    memset(underrun, 0x7f, sizeof(underrun));

    OSStatus status = (*driver)->StartIO(driver, deviceObjectID, 1);
    if (status != 0) return 2;
    status = (*driver)->DoIOOperation(
        driver, deviceObjectID, outputStreamObjectID, 1,
        kAudioServerPlugInIOOperationWriteMix, frameCount, &cycle,
        source, NULL
    );
    if (status != 0) return 3;
    status = (*driver)->DoIOOperation(
        driver, deviceObjectID, inputStreamObjectID, 2,
        kAudioServerPlugInIOOperationReadInput, frameCount, &cycle,
        destination, NULL
    );
    if (status != 0) return 4;

    for (int sample = 0; sample < frameCount * 2; ++sample) {
        if (fabsf(source[sample] - destination[sample]) > 0.000001f) {
            fprintf(stderr, "loopback mismatch at sample %d\n", sample);
            return 5;
        }
    }

    status = (*driver)->DoIOOperation(
        driver, deviceObjectID, inputStreamObjectID, 2,
        kAudioServerPlugInIOOperationReadInput, frameCount, &cycle,
        underrun, NULL
    );
    if (status != 0) return 6;
    for (int sample = 0; sample < frameCount * 2; ++sample) {
        if (underrun[sample] != 0.0f) {
            fprintf(stderr, "underrun was not silent at sample %d\n", sample);
            return 7;
        }
    }

    status = (*driver)->StopIO(driver, deviceObjectID, 1);
    if (status != 0) return 8;
    printf("DualSense Bridge Mic FIFO passed %d-frame loopback and underrun tests\n", frameCount);
    return 0;
}
