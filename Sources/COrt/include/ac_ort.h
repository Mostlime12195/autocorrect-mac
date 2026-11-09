// Narrow C wrapper over the onnxruntime C API: open a (memory-mapped) session, run it with named tensors, copy the
// float outputs out. Keeps the Swift side free of OrtApi function-pointer plumbing.
#ifndef AC_ORT_H
#define AC_ORT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// element types (= ONNXTensorElementDataType values)
enum { AC_FLOAT = 1, AC_INT32 = 6, AC_INT64 = 7, AC_BOOL = 9 };

typedef struct AcSession AcSession;

typedef struct {
    const char *name;
    int type;
    const void *data;
    const int64_t *shape;
    size_t rank;
} AcInput;

typedef struct {
    float *data;        // malloc'd copy, freed by ac_outputs_free
    size_t count;
    int64_t shape[8];
    size_t rank;
} AcOutput;

/// ort_format: the file is a pre-optimized .ort graph (no runtime optimization, initializers used from the mapping).
AcSession *ac_session_open(const char *path, int threads, int ort_format, char *err, size_t errlen);
int ac_session_run(AcSession *s, const AcInput *inputs, size_t n_inputs, const char *const *output_names,
                   size_t n_outputs, AcOutput *outputs, char *err, size_t errlen);
void ac_outputs_free(AcOutput *outputs, size_t n);
size_t ac_session_input_count(AcSession *s);
/// copies input name i into buf; 0 on success
int ac_session_input_name(AcSession *s, size_t i, char *buf, size_t len);
void ac_session_close(AcSession *s);
const char *ac_ort_version(void);

#ifdef __cplusplus
}
#endif
#endif
