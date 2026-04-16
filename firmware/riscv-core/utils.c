#include "../../training/model_data.h"

void conv2d(const float *input, const float *kernel, float *output, int input_width, int input_height, int kernel_size) {
    int output_width = input_width - kernel_size + 1;
    int output_height = input_height - kernel_size + 1;

    for (int i = 0; i < output_height; i++) {
        for (int j = 0; j < output_width; j++) {
            float sum = 0.0f;
            for (int k = 0; k < kernel_size; k++) {
                for (int l = 0; l < kernel_size; l++) {
                    sum += input[(i + k) * input_width + (j + l)] * kernel[k * kernel_size + l];
                }
            }
            output[i * output_width + j] = sum;
        }
    }
}