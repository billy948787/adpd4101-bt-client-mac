#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>
#import "bt_bridge.h"

static DataCallback globalCallback = NULL;
static volatile bool isRunning = true;

@interface BTDelegate : NSObject <IOBluetoothRFCOMMChannelDelegate>
@property (assign) BOOL isActive;
@end

@implementation BTDelegate

- (void)rfcommChannelOpenComplete:(IOBluetoothRFCOMMChannel *)channel status:(IOReturn)status opID:(int)opID {
    if (!self.isActive) return;
    if (status == kIOReturnSuccess) {
        printf(">>> [Mac] RFCOMM Channel 連線成功!\n");
    } else {
        printf(">>> [Mac] RFCOMM 連線失敗，錯誤碼: 0x%x\n", status);
        isRunning = false;
    }
}

- (void)rfcommChannelData:(IOBluetoothRFCOMMChannel *)channel data:(void *)dataPointer length:(size_t)dataLength {
    if (!self.isActive) return;
    if (globalCallback) {
        globalCallback((const uint8_t*)dataPointer, dataLength);
    }
}

- (void)rfcommChannelClosed:(IOBluetoothRFCOMMChannel *)channel {
    if (!self.isActive) return;
    printf(">>> [Mac] RFCOMM Channel 已關閉\n");
    isRunning = false;
}

@end

void stop_bluetooth_loop() {
    isRunning = false;
}

static void interruptible_sleep(double seconds) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (isRunning && [deadline timeIntervalSinceNow] > 0) {
        [NSThread sleepForTimeInterval:0.1];
    }
}

void start_bluetooth_connection(const char* mac_addr, int channel_id, DataCallback callback) {
    globalCallback = callback;
    isRunning = true;

    @autoreleasepool {
        NSString *addrStr = [NSString stringWithUTF8String:mac_addr];
        IOBluetoothDevice *device = [IOBluetoothDevice deviceWithAddressString:addrStr];

        if (!device) {
            printf("錯誤: 找不到裝置 %s\n", mac_addr);
            return;
        }

        if ([device isConnected]) {
            printf(">>> [Mac] 偵測到舊連線殘留，先強制關閉...\n");
            [device closeConnection];
            interruptible_sleep(2.0);
            if (!isRunning) return;
        }

        // 建立底層連線，最多 retry 5 次
        IOReturn ret = kIOReturnError;
        for (int attempt = 1; attempt <= 5 && isRunning; attempt++) {
            printf(">>> [Mac] 建立底層連線... (第 %d 次)\n", attempt);
            ret = [device openConnection];
            if (ret == kIOReturnSuccess) {
                printf(">>> [Mac] 底層連線建立，等待 1 秒讓訊號穩定...\n");
                interruptible_sleep(1.0);
                break;
            }
            printf(">>> [Mac] 底層連線失敗 (0x%x)，等待 2 秒後重試...\n", ret);
            interruptible_sleep(2.0);
        }

        if (!isRunning) { printf(">>> [Mac] 收到中斷信號\n"); return; }
        if (ret != kIOReturnSuccess) { printf("錯誤: 底層連線重試 5 次仍失敗\n"); return; }

        // 開啟 RFCOMM Channel，直接跑 RunLoop，不等 openComplete
        printf(">>> [Mac] 正在開啟 RFCOMM Channel %d...\n", channel_id);
        BTDelegate *delegate = [[BTDelegate alloc] init];
        delegate.isActive = YES;
        IOBluetoothRFCOMMChannel *channel = nil;
        ret = [device openRFCOMMChannelAsync:&channel withChannelID:channel_id delegate:delegate];

        if (ret != kIOReturnSuccess || channel == nil) {
            printf("錯誤: 無法發起 RFCOMM 連線 (0x%x)\n", ret);
            [device closeConnection];
            return;
        }

        // 直接進 RunLoop，callback 自己會來
        printf(">>> [Mac] 進入事件迴圈...\n");
        while (isRunning) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                    beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        }

        // 優雅清理
        delegate.isActive = NO;
        printf(">>> [Mac] 正在關閉連線...\n");
        if (channel && [channel isOpen]) {
            [channel closeChannel];
            NSDate *closeDeadline = [NSDate dateWithTimeIntervalSinceNow:1.0];
            while ([closeDeadline timeIntervalSinceNow] > 0) {
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                        beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
            }
        }
        if ([device isConnected]) {
            [device closeConnection];
        }
        [NSThread sleepForTimeInterval:1.5];
        printf(">>> [Mac] 連線已完整關閉\n");
    }
}

void cleanup_bluetooth_connection(const char* mac_addr) {
    @autoreleasepool {
        NSString *addrStr = [NSString stringWithUTF8String:mac_addr];
        IOBluetoothDevice *device = [IOBluetoothDevice deviceWithAddressString:addrStr];
        if ([device isConnected]) {
            printf(">>> [Mac] 清理連線: 關閉底層連線...\n");
            [device closeConnection];
        }
    }
}
