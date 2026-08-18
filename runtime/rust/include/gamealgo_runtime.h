#ifndef GAMEALGO_RUNTIME_H
#define GAMEALGO_RUNTIME_H

#ifdef __cplusplus
extern "C" {
#endif

char *gamealgo_runtime_execute(const char *request_json);
char *gamealgo_runtime_prepare(const char *script);
char *gamealgo_runtime_execute_prepared(void *handle, const char *input_json);
void gamealgo_runtime_release(void *handle);
void gamealgo_runtime_free(char *value);

#ifdef __cplusplus
}
#endif

#endif
