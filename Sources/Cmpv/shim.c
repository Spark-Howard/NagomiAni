// 在新 SDK 中 CGLGetProcAddress 声明已被移除，这里用 dlsym 在运行时解析。
#include <dlfcn.h>
#include <stddef.h>
#include "nagomiru_shim.h"

void *nagomiru_gl_get_proc_address(void *ctx, const char *name) {
    (void)ctx;
    if (!name) return NULL;
    static void *handle = NULL;
    if (!handle) {
        handle = dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL",
                        RTLD_LAZY | RTLD_LOCAL);
    }
    if (!handle) return NULL;
    return dlsym(handle, name);
}
