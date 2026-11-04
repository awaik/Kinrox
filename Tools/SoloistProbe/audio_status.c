// Read-only Core Audio process status; never captures samples or changes devices/gain.
#include <CoreAudio/CoreAudio.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    char *end;
    long value = strtol(argv[1], &end, 10);
    if (*end || value < 2 || value > 2147483647) return 2;
    pid_t pid = (pid_t)value;
    AudioObjectID object = kAudioObjectUnknown;
    UInt32 size = sizeof(object);
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyTranslatePIDToProcessObject,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
    };
    OSStatus result = AudioObjectGetPropertyData(kAudioObjectSystemObject,
        &address, sizeof(pid), &pid, &size, &object);
    if (result != noErr) {
        printf("{\"query_status\":%d}\n", (int)result);
        return 3;
    }
    if (object == kAudioObjectUnknown) {
        puts("{\"query_status\":0,\"process_registered\":false}");
        return 0;
    }
    UInt32 output = 0;
    size = sizeof(output);
    address.mSelector = kAudioProcessPropertyIsRunningOutput;
    result = AudioObjectGetPropertyData(object, &address, 0, NULL, &size, &output);
    if (result != noErr) {
        printf("{\"query_status\":%d,\"process_registered\":true}\n", (int)result);
        return 3;
    }
    AudioObjectID defaultOutput = kAudioObjectUnknown;
    size = sizeof(defaultOutput);
    address.mSelector = kAudioHardwarePropertyDefaultOutputDevice;
    result = AudioObjectGetPropertyData(kAudioObjectSystemObject, &address,
        0, NULL, &size, &defaultOutput);
    if (result != noErr) return 3;
    AudioObjectID devices[64];
    size = sizeof(devices);
    address.mSelector = kAudioProcessPropertyDevices;
    address.mScope = kAudioObjectPropertyScopeOutput;
    result = AudioObjectGetPropertyData(object, &address, 0, NULL, &size, devices);
    if (result != noErr) return 3;
    int usesDefault = 0;
    for (UInt32 i = 0; i < size / sizeof(AudioObjectID); ++i) {
        if (devices[i] == defaultOutput) usesDefault = 1;
    }
    printf("{\"query_status\":0,\"process_registered\":true,"
        "\"output_running\":%s,\"uses_default_output\":%s}\n",
        output ? "true" : "false", usesDefault ? "true" : "false");
    // An active output stream is not proof that decoded Spotify frames reached it.
    return 0;
}
