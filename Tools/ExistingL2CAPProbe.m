#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>

static void probe(IOBluetoothDevice *device, BluetoothL2CAPPSM psm, const char *name) {
    IOBluetoothL2CAPChannel *channel = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    IOReturn status = [device openL2CAPChannel:psm
                                  findExisting:YES
                                     newChannel:&channel];
#pragma clang diagnostic pop

    if (channel) {
        printf("%s status=%d object=%lu psm=%u outMTU=%u inMTU=%u incoming=%d\n",
               name,
               status,
               (unsigned long)channel.objectID,
               channel.PSM,
               channel.outgoingMTU,
               channel.incomingMTU,
               channel.isIncoming);
    } else {
        printf("%s status=%d channel=nil\n", name, status);
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) {
            fprintf(stderr, "usage: ExistingL2CAPProbe bluetooth-address\n");
            return 2;
        }

        NSString *address = [NSString stringWithUTF8String:argv[1]];
        IOBluetoothDevice *device = [IOBluetoothDevice deviceWithAddressString:address];
        if (!device) {
            fprintf(stderr, "device not found\n");
            return 3;
        }

        printf("connected=%d address=%s\n", device.isConnected, argv[1]);
        probe(device, kBluetoothL2CAPPSMHIDControl, "control");
        probe(device, kBluetoothL2CAPPSMHIDInterrupt, "interrupt");
    }
    return 0;
}
