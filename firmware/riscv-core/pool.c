#include "../../training/model_data.h"

#define INFINITY (1.0f/0.0f)

void max_pool2d(const float *input, float *output, int input_width, int input_height, int pool_size, int stride) {
    int output_width = (input_width - pool_size) / stride + 1;
    int output_height = (input_height - pool_size) / stride + 1;

    for (int i = 0; i < output_height; i++) {
        for (int j = 0; j < output_width; j++) {
            float max_val = -INFINITY;
            for (int k = 0; k < pool_size; k++) {
                for (int l = 0; l < pool_size; l++) {
                    int x = j * stride + l;
                    int y = i * stride + k;
                    max_val = fmaxf(max_val, input[y * input_width + x]);
                }
            }
            output[i * output_width + j] = max_val;
        }
    }
}
