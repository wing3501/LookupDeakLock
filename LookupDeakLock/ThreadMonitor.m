//
//  ThreadMonitor.m
//  LookupDeakLock
//
//  Created by styf on 2021/12/1.
//

#import "ThreadMonitor.h"
#include <mach/mach.h>
#import <pthread.h>
#import <dlfcn.h>
#import <os/lock.h>
#include "KSThread.h"
@implementation ThreadMonitor

//如何系统性治理 iOS 稳定性问题
//https://mp.weixin.qq.com/s?__biz=Mzg2NTYyMjYxNg==&mid=2247485592&idx=1&sn=6ff5f4f93294c6e01c50a3b6687ccfd6&scene=21#wechat_redirect
+ (void)checkThreads {
    // 获取线程列表
    // 参考 KSMachineContext.c    ksmc_suspendEnvironment
    // 参考 SMCPUMonitor.m       updateCPU
    thread_act_array_t threads = NULL;
    mach_msg_type_number_t numThreads = 0;
    kern_return_t kr;
    const task_t thisTask = mach_task_self();
    if((kr = task_threads(thisTask, &threads, &numThreads)) != KERN_SUCCESS)
    {
        NSLog(@"task_threads: %s", mach_error_string(kr));
        return;
    }
    
    // 保存线程描述信息
    NSMutableDictionary<NSNumber *,NSString *> *threadDescDic = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *,NSMutableArray<NSNumber *> *> *threadWaitDic = [NSMutableDictionary dictionary];
    
    // 获取线程信息
    // 参考 KSThread.c    ksthread_getQueueName
    // 参考 SMCallStack.m   smStackOfThread
    const thread_t thisThread = (thread_t)thread_self();
    for(mach_msg_type_number_t i = 0; i < numThreads; i++) {
        if (threads[i] == thisThread) {
            continue;
        }
        // 线程基本信息 名称 cpu占用等
        thread_extended_info_data_t threadInfoData;
        mach_msg_type_number_t threadInfoCount = THREAD_EXTENDED_INFO_COUNT;
        
        // 线程id 队列
        thread_identifier_info_data_t threadIDData;
        mach_msg_type_number_t threadIDDataCount = THREAD_IDENTIFIER_INFO_COUNT;
        
        if (thread_info((thread_act_t)threads[i], THREAD_EXTENDED_INFO, (thread_info_t)&threadInfoData, &threadInfoCount) == KERN_SUCCESS &&
            thread_info((thread_act_t)threads[i], THREAD_IDENTIFIER_INFO, (thread_info_t)&threadIDData, &threadIDDataCount) == KERN_SUCCESS) {
            uint64_t thread_id = threadIDData.thread_id;
            integer_t cpu_usage = threadInfoData.pth_cpu_usage;
            integer_t run_state = threadInfoData.pth_run_state;
            integer_t flags = threadInfoData.pth_flags;
            char *pth_name = threadInfoData.pth_name;
            int queueNameLen = 128;
            char queueName[queueNameLen];
            bool getQueueNameSuccess = ksthread_getQueueName((thread_t)threads[i], queueName, queueNameLen);
            NSString *threadDesc = [NSString stringWithFormat:@"[%llu %s %s ] [run_state: %d] [flags : %d] [cpu_usage : %d]",thread_id,pth_name,getQueueNameSuccess ? queueName : "",run_state,flags,cpu_usage];
            threadDescDic[@(thread_id)] = threadDesc;
            
            //我们主要的分析思路有两种：
            //第一种，如果看到主线程的 CPU 占用为 0，当前处于等待的状态，已经被换出，那我们就有理由怀疑当前这次卡死可能是因为死锁导致的
//            NSLog(@" %u %s [run_state: %d]  [flags : %d] [cpu_usage : %d]-------------",threads[i],threadInfoData.pth_name,run_state,flags,cpu_usage);
            if ((run_state & TH_STATE_WAITING) && (flags & TH_FLAGS_SWAPPED) && cpu_usage == 0) {
                //怀疑死锁
                //我们可以在卡死时获取到所有线程的状态并且筛选出所有处于等待状态的线程，再获取每个线程当前的 PC 地址，也就是正在执行的方法，并通过符号化判断它是否是一个锁等待的方法。
                // 参考 SMCallStack.m   smStackOfThread
                // 参考 KSStackCursor
                _STRUCT_MCONTEXT machineContext;
                //通过 thread_get_state 获取完整的 machineContext 信息，包含 thread 状态信息
                mach_msg_type_number_t state_count = smThreadStateCountByCPU();
                kern_return_t kr = thread_get_state(threads[i], smThreadStateByCPU(), (thread_state_t)&machineContext.__ss, &state_count);
                if (kr != KERN_SUCCESS) {
                    NSLog(@"Fail get thread: %u", threads[i]);
                    continue;
                }
                //通过指令指针来获取当前指令地址
                const uintptr_t instructionAddress = smMachInstructionPointerByCPU(&machineContext);
                Dl_info info;
                dladdr((void *)instructionAddress, &info);
//                NSLog(@"指令是啥----------%s %s",info.dli_sname,info.dli_fname);
                if (strcmp(info.dli_sname, "__psynch_mutexwait") == 0) {
//                    __psynch_mutexwait /usr/lib/system/libsystem_kernel.dylib
                    
                    // 参考  libpthread-454.80.2
//                    extern uint32_t __psynch_mutexwait(pthread_mutex_t *mutex,  uint32_t mgen, uint32_t  ugen, uint64_t tid, uint32_t flags);
                    // 参考 types_internal.h
                    uintptr_t firstParam = firstParamRegister(&machineContext);
                    struct pthread_mutex_s *mutex = (struct pthread_mutex_s *)firstParam;
                    uint32_t *tid = mutex->psynch.m_tid;
                    uint64_t hold_lock_thread_id = *tid;
//                    NSLog(@"谁持有了？------>%d", *tid);
                    
                    //需要判断死锁
                    NSMutableArray *array = threadWaitDic[@(hold_lock_thread_id)];
                    if (!array) {
                        array = [NSMutableArray array];
                    }
                    [array addObject:@(thread_id)];
                    threadWaitDic[@(hold_lock_thread_id)] = array;

                }
                //其他锁情况 TODO
                //__psynch_rw_rdlock   ReadWrite lock
                //__psynch_rw_wrlock   ReadWrite lock
                //__ulock_wait         UnfariLock lock
                //_kevent_id           GCD lock
            }
            //另外一种，特征有所区别，主线程的 CPU 占用一直很高 ，处于运行的状态，那么就应该怀疑主线程是否存在一些死循环等 CPU 密集型的任务。
            if ((run_state & TH_STATE_RUNNING) && cpu_usage > 800) {
                //怀疑死循环
                //参考 [SMCPUMonitor updateCPU]
                NSLog(@"怀疑死循环:%@",threadDesc);
            }
        }
    }
    
    if (threadWaitDic.count > 1) {
        //需要判断死锁
        [self checkIfIsCircleWithThreadDescDic:threadDescDic threadWaitDic:threadWaitDic];
    }
    
    return;

}

/// 判断是否死锁
/// @param threadDescDic 线程描述信息
/// @param threadWaitDic 线程等待信息
+ (void)checkIfIsCircleWithThreadDescDic:(NSMutableDictionary<NSNumber *,NSString *> *)threadDescDic threadWaitDic:(NSMutableDictionary<NSNumber *,NSMutableArray<NSNumber *> *> *)threadWaitDic {
    __block BOOL hasCircle = NO;
    NSMutableDictionary<NSNumber *,NSNumber *> *visited = [NSMutableDictionary dictionary];
    NSMutableArray *path = [NSMutableArray array];
    [threadWaitDic enumerateKeysAndObjectsUsingBlock:^(NSNumber * _Nonnull hold_lock_thread_id, NSMutableArray<NSNumber *> * _Nonnull waitArray, BOOL * _Nonnull stop) {
        [self checkThreadID:hold_lock_thread_id withThreadDescDic:threadDescDic threadWaitDic:threadWaitDic visited:visited path:path hasCircle:&hasCircle];
        if (hasCircle) {
            *stop = YES;
        }
    }];
    
    if (hasCircle) {
        NSLog(@"发现死锁如下：");
        for (NSNumber *threadID in path) {
            NSLog(@"%@",threadDescDic[threadID]);
        }
    }else {
        NSLog(@"未发现死锁");
    }
}

+ (void)checkThreadID:(NSNumber *)threadID withThreadDescDic:(NSMutableDictionary<NSNumber *,NSString *> *)threadDescDic threadWaitDic:(NSMutableDictionary<NSNumber *,NSMutableArray<NSNumber *> *> *)threadWaitDic visited:(NSMutableDictionary<NSNumber *,NSNumber *> *)visited path:(NSMutableArray *)path hasCircle:(BOOL *)hasCircle {
    if (visited[threadID]) {
        *hasCircle = YES;
        NSUInteger index = [path indexOfObject:threadID];
        path = [[path subarrayWithRange:NSMakeRange(index, path.count - index)] mutableCopy];
    }
    if (*hasCircle) {
        return;
    }
    
    visited[threadID] = @1;
    [path addObject:threadID];
    NSMutableArray *array = threadWaitDic[threadID];
    if (array.count) {
        for (NSNumber *next in array) {
            [self checkThreadID:next withThreadDescDic:threadDescDic threadWaitDic:threadWaitDic visited:visited path:path hasCircle:hasCircle];
        }
    }
    [visited removeObjectForKey:threadID];
}


typedef os_unfair_lock _pthread_lock;

struct pthread_mutex_options_s {
    uint32_t
        protocol:2,
        type:2,
        pshared:2,
        policy:3,
        hold:2,
        misalign:1,
        notify:1,
        mutex:1,
        ulock:1,
        unused:1,
        lock_count:16;
};

typedef struct _pthread_mutex_ulock_s {
    uint32_t uval;
} *_pthread_mutex_ulock_t;

struct pthread_mutex_s {
    long sig;
    _pthread_lock lock;
    union {
        uint32_t value;
        struct pthread_mutex_options_s options;
    } mtxopts;
    int16_t prioceiling;
    int16_t priority;
#if defined(__LP64__)
    uint32_t _pad;
#endif
    union {
        struct {
            uint32_t m_tid[2]; // thread id of thread that has mutex locked
            uint32_t m_seq[2]; // mutex sequence id
            uint32_t m_mis[2]; // for misaligned locks m_tid/m_seq will span into here
        } psynch;
        struct _pthread_mutex_ulock_s ulock;
    };
#if defined(__LP64__)
    uint32_t _reserved[4];
#else
    uint32_t _reserved[1];
#endif
};




uintptr_t firstParamRegister(mcontext_t const machineContext) {
#if defined(__arm64__)
    return machineContext->__ss.__x[0];
#elif defined(__arm__)
    return machineContext->__ss.__x[0];
#elif defined(__x86_64__)
    return machineContext->__ss.__rdi;
#endif
}

thread_state_flavor_t smThreadStateByCPU(void) {
#if defined(__arm64__)
    return ARM_THREAD_STATE64;
#elif defined(__arm__)
    return ARM_THREAD_STATE;
#elif defined(__x86_64__)
    return x86_THREAD_STATE64;
#elif defined(__i386__)
    return x86_THREAD_STATE32;
#endif
}
mach_msg_type_number_t smThreadStateCountByCPU(void) {
#if defined(__arm64__)
    return ARM_THREAD_STATE64_COUNT;
#elif defined(__arm__)
    return ARM_THREAD_STATE_COUNT;
#elif defined(__x86_64__)
    return x86_THREAD_STATE64_COUNT;
#elif defined(__i386__)
    return x86_THREAD_STATE32_COUNT;
#endif
}
uintptr_t smMachInstructionPointerByCPU(mcontext_t const machineContext) {
    //Instruction pointer. Holds the program counter, the current instruction address.
#if defined(__arm64__)
    return machineContext->__ss.__pc;
#elif defined(__arm__)
    return machineContext->__ss.__pc;
#elif defined(__x86_64__)
    return machineContext->__ss.__rip;
#elif defined(__i386__)
    return machineContext->__ss.__eip;
#endif
}

uintptr_t thread_self(void) {
    // 一个“反问”引发的内存反思：https://blog.csdn.net/killer1989/article/details/106674973
    thread_t thread_self = mach_thread_self();
    mach_port_deallocate(mach_task_self(), thread_self);
    return thread_self;
}

@end
