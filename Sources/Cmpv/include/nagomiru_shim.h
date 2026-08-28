#ifndef NAGOMIRU_SHIM_H
#define NAGOMIRU_SHIM_H

// 解析 OpenGL 函数指针（替代新 SDK 中已移除的 CGLGetProcAddress）
void *nagomiru_gl_get_proc_address(void *ctx, const char *name);

#endif
