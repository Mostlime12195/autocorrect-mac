#include "ac_ort.h"

#include <fcntl.h>
#include <onnxruntime_c_api.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

static const OrtApi *g_api;
static OrtEnv *g_env;
static pthread_once_t g_once = PTHREAD_ONCE_INIT;

static void init_once(void) {
    const OrtApiBase *base = OrtGetApiBase();
    if (!base) return;
    g_api = base->GetApi(ORT_API_VERSION);
    if (!g_api) return;
    OrtStatus *st = g_api->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "autocorrect", &g_env);
    if (st) { g_api->ReleaseStatus(st); g_env = NULL; }
}

struct AcSession {
    OrtSession *session;
    OrtMemoryInfo *mem;
    void *map;
    size_t map_len;
};

static int take(OrtStatus *st, char *err, size_t errlen) {
    if (!st) return 0;
    if (err && errlen) snprintf(err, errlen, "%s", g_api->GetErrorMessage(st));
    g_api->ReleaseStatus(st);
    return 1;
}

#define TRY(x) do { if (take((x), err, errlen)) goto fail; } while (0)

const char *ac_ort_version(void) {
    const OrtApiBase *base = OrtGetApiBase();
    return base ? base->GetVersionString() : "?";
}

AcSession *ac_session_open(const char *path, int threads, int ort_format, char *err, size_t errlen) {
    pthread_once(&g_once, init_once);
    if (!g_api || !g_env) { snprintf(err, errlen, "onnxruntime init failed (API version %d)", ORT_API_VERSION); return NULL; }
    AcSession *s = calloc(1, sizeof(AcSession));
    OrtSessionOptions *opts = NULL;
    int fd = open(path, O_RDONLY);
    if (fd < 0) { snprintf(err, errlen, "cannot open %s", path); free(s); return NULL; }
    struct stat sb;
    if (fstat(fd, &sb) != 0 || sb.st_size <= 0) { close(fd); snprintf(err, errlen, "cannot stat %s", path); free(s); return NULL; }
    s->map_len = (size_t)sb.st_size;
    s->map = mmap(NULL, s->map_len, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (s->map == MAP_FAILED) { s->map = NULL; snprintf(err, errlen, "mmap failed for %s", path); free(s); return NULL; }

    TRY(g_api->CreateSessionOptions(&opts));
    TRY(g_api->SetIntraOpNumThreads(opts, threads));
    TRY(g_api->SetInterOpNumThreads(opts, 1));
    // the CPU arena keeps the largest batch's buffers forever; plain malloc gives them back
    TRY(g_api->DisableCpuMemArena(opts));
    // workers block instead of spinning: short bursts at word end, sharing the CPU with the app being typed in
    TRY(g_api->AddSessionConfigEntry(opts, "session.intra_op.allow_spinning", "0"));
    if (ort_format) {
        TRY(g_api->SetSessionGraphOptimizationLevel(opts, ORT_DISABLE_ALL));
        TRY(g_api->AddSessionConfigEntry(opts, "session.load_model_format", "ORT"));
        TRY(g_api->AddSessionConfigEntry(opts, "session.use_ort_model_bytes_directly", "1"));
        TRY(g_api->AddSessionConfigEntry(opts, "session.use_ort_model_bytes_for_initializers", "1"));
    } else {
        TRY(g_api->SetSessionGraphOptimizationLevel(opts, ORT_ENABLE_ALL));
    }
    TRY(g_api->CreateSessionFromArray(g_env, s->map, s->map_len, opts, &s->session));
    TRY(g_api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &s->mem));
    g_api->ReleaseSessionOptions(opts);
    return s;
fail:
    if (opts) g_api->ReleaseSessionOptions(opts);
    ac_session_close(s);
    return NULL;
}

static size_t elem_size(int type) {
    switch (type) {
        case AC_FLOAT: case AC_INT32: return 4;
        case AC_INT64: return 8;
        case AC_BOOL: return 1;
        default: return 0;
    }
}

int ac_session_run(AcSession *s, const AcInput *inputs, size_t n_inputs, const char *const *output_names,
                   size_t n_outputs, AcOutput *outputs, char *err, size_t errlen) {
    OrtValue **in = calloc(n_inputs, sizeof(OrtValue *));
    OrtValue **out = calloc(n_outputs, sizeof(OrtValue *));
    const char **names = calloc(n_inputs, sizeof(char *));
    int rc = 1;
    memset(outputs, 0, n_outputs * sizeof(AcOutput));
    for (size_t i = 0; i < n_inputs; i++) {
        const AcInput *x = &inputs[i];
        size_t count = 1;
        for (size_t d = 0; d < x->rank; d++) count *= (size_t)x->shape[d];
        size_t es = elem_size(x->type);
        if (!es) { snprintf(err, errlen, "input %s: unsupported type %d", x->name, x->type); goto fail; }
        names[i] = x->name;
        // a zero-element tensor still needs a valid pointer
        static const int64_t dummy = 0;
        void *data = (void *)(count ? x->data : &dummy);
        TRY(g_api->CreateTensorWithDataAsOrtValue(s->mem, data, count * es, x->shape, x->rank,
                                                  (ONNXTensorElementDataType)x->type, &in[i]));
    }
    TRY(g_api->Run(s->session, NULL, names, (const OrtValue *const *)in, n_inputs, output_names, n_outputs, out));
    for (size_t i = 0; i < n_outputs; i++) {
        OrtTensorTypeAndShapeInfo *info = NULL;
        TRY(g_api->GetTensorTypeAndShape(out[i], &info));
        ONNXTensorElementDataType t;
        size_t count = 0, rank = 0;
        OrtStatus *st = g_api->GetTensorElementType(info, &t);
        if (!st) st = g_api->GetTensorShapeElementCount(info, &count);
        if (!st) st = g_api->GetDimensionsCount(info, &rank);
        if (!st && rank > 8) { g_api->ReleaseTensorTypeAndShapeInfo(info); snprintf(err, errlen, "rank > 8"); goto fail; }
        if (!st) st = g_api->GetDimensions(info, outputs[i].shape, rank);
        g_api->ReleaseTensorTypeAndShapeInfo(info);
        TRY(st);
        if (t != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) { snprintf(err, errlen, "output %s is not float", output_names[i]); goto fail; }
        float *src = NULL;
        TRY(g_api->GetTensorMutableData(out[i], (void **)&src));
        outputs[i].data = malloc(count ? count * sizeof(float) : 1);
        if (count) memcpy(outputs[i].data, src, count * sizeof(float));
        outputs[i].count = count;
        outputs[i].rank = rank;
    }
    rc = 0;
fail:
    for (size_t i = 0; i < n_inputs; i++) if (in[i]) g_api->ReleaseValue(in[i]);
    for (size_t i = 0; i < n_outputs; i++) if (out[i]) g_api->ReleaseValue(out[i]);
    if (rc) ac_outputs_free(outputs, n_outputs);
    free(in); free(out); free(names);
    return rc;
}

void ac_outputs_free(AcOutput *outputs, size_t n) {
    for (size_t i = 0; i < n; i++) { free(outputs[i].data); outputs[i].data = NULL; outputs[i].count = 0; }
}

size_t ac_session_input_count(AcSession *s) {
    size_t n = 0;
    OrtStatus *st = g_api->SessionGetInputCount(s->session, &n);
    if (st) { g_api->ReleaseStatus(st); return 0; }
    return n;
}

int ac_session_input_name(AcSession *s, size_t i, char *buf, size_t len) {
    OrtAllocator *alloc = NULL;
    OrtStatus *st = g_api->GetAllocatorWithDefaultOptions(&alloc);
    if (st) { g_api->ReleaseStatus(st); return 1; }
    char *name = NULL;
    st = g_api->SessionGetInputName(s->session, i, alloc, &name);
    if (st) { g_api->ReleaseStatus(st); return 1; }
    snprintf(buf, len, "%s", name);
    (void)alloc->Free(alloc, name);
    return 0;
}

void ac_session_close(AcSession *s) {
    if (!s) return;
    if (s->session) g_api->ReleaseSession(s->session);
    if (s->mem) g_api->ReleaseMemoryInfo(s->mem);
    if (s->map) munmap(s->map, s->map_len);
    free(s);
}
