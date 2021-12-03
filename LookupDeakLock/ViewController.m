//
//  ViewController.m
//  LookupDeakLock
//
//  Created by styf on 2021/12/1.
//

#import "ViewController.h"
#import "ThreadMonitor.h"
@interface ViewController ()
/// <#name#>
@property (nonatomic, assign) BOOL checkThreadCancel;
/// <#name#>
@property (nonatomic, strong) NSThread *manyWorkThread;
/// <#name#>
@property (nonatomic, strong) NSThread *holdLockAThread;
/// <#name#>
@property (nonatomic, strong) NSLock *lockA;
/// <#name#>
@property (nonatomic, strong) NSThread *holdLockBThread;
/// <#name#>
@property (nonatomic, strong) NSLock *lockB;
/// <#name#>
@property (nonatomic, strong) NSThread *holdLockCThread;
/// <#name#>
@property (nonatomic, strong) NSLock *lockC;

/// <#name#>
@property (nonatomic, strong) NSThread *holdlockSemaphoreThread;
/// <#name#>
@property (nonatomic, strong) dispatch_semaphore_t lockSemaphore;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    _lockA = [[NSLock alloc]init];
    _lockA.name = @"I am LockA";
    
    _lockB = [[NSLock alloc]init];
    _lockB.name = @"I am LockB";
    
    _lockC = [[NSLock alloc]init];
    _lockC.name = @"I am LockC";
    
    _lockSemaphore = dispatch_semaphore_create(1);
    
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        while (!weakSelf.checkThreadCancel) {
            [ThreadMonitor checkThreads];
            sleep(3);
        }
    });
    
//    [self testDoManyWork];
    
    [self testWaitNSLock];
    

    
    
//    _holdlockSemaphoreThread = [[NSThread alloc]initWithTarget:self selector:@selector(holdlockSemaphore) object:nil];
//    [_holdlockSemaphoreThread setName:@"I hold lockSemaphore!"];
//    [_holdlockSemaphoreThread start];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    
}

- (void)testWaitNSLock {
    _holdLockAThread = [[NSThread alloc]initWithTarget:self selector:@selector(holdLockA) object:nil];
    [_holdLockAThread setName:@"I hold LockA!"];
    [_holdLockAThread start];
    
    _holdLockBThread = [[NSThread alloc]initWithTarget:self selector:@selector(holdLockB) object:nil];
    [_holdLockBThread setName:@"I hold LockB!"];
    [_holdLockBThread start];
    
    _holdLockCThread = [[NSThread alloc]initWithTarget:self selector:@selector(holdLockC) object:nil];
    [_holdLockCThread setName:@"I hold LockC!"];
    [_holdLockCThread start];
}

- (void)testDoManyWork {
    _manyWorkThread = [[NSThread alloc]initWithTarget:self selector:@selector(doManyWork) object:nil];
    [_manyWorkThread setName:@"I am busy!"];
    [_manyWorkThread start];
}

- (void)holdlockSemaphore {
    dispatch_semaphore_wait(_lockSemaphore, DISPATCH_TIME_FOREVER);
    NSLog(@"BThread hold lockSemaphore success");
    sleep(2);
    
    NSLog(@"BThread want lockA");
    [_lockA lock];
    NSLog(@"BThread hold lockA success");
}

- (void)holdLockA {
    [_lockA lock];
    
    NSLog(@"AThread hold lockA success");
    sleep(2);
    
    NSLog(@"AThread want lockB");
    [_lockB lock];
    NSLog(@"AThread hold lockB success");
}

- (void)holdLockB {
    [_lockB lock];
    
    NSLog(@"BThread hold lockB success");
    sleep(2);
    
    NSLog(@"BThread want lockC");
    [_lockC lock];
    NSLog(@"BThread hold lockC success");
}

- (void)holdLockC {
    [_lockC lock];
    
    NSLog(@"CThread hold lockC success");
    sleep(2);
    
    NSLog(@"CThread want lockA");
    [_lockA lock];
    NSLog(@"CThread hold lockA success");
}

- (void)doManyWork {
    NSLog(@"doManyWork start");
    int a = 0;
    for (int i = 0; i < 10000000; i++) {
        a = i;
        for (int j = 0; j < 10000000; j++) {
            a--;
        }
    }
    NSLog(@"doManyWork end");
}
@end
