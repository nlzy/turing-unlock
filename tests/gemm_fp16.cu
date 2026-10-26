// SPDX-License-Identifier: GPL-2.0-only
// cuBLAS FP16 matrix multiply with FP32 accumulate, the benchmark behind the
// README's Performance table. Exits 1 if the largest size stays below
// --min-tflops, so a locked card fails and an unlocked one passes.
//
//   gemm_fp16 [-d PCI_ADDRESS|INDEX] [--min-tflops N]
//
// Turing's FP16 tensor peak is 56.9 TFLOPS; the default threshold of 70 is
// above what a locked card reaches and well below an unlocked one.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cuda_runtime.h>
#include <cublas_v2.h>

static const int sizes[] = {1024, 2048, 4096, 8192};

static double bench(cublasHandle_t h, int n)
{
	void *a, *b, *c;
	size_t bytes = (size_t)n * n * 2;
	float alpha = 1, beta = 0;
	cudaEvent_t t0, t1;
	float ms;
	const int iters = 200;

	cudaMalloc(&a, bytes);
	cudaMalloc(&b, bytes);
	cudaMalloc(&c, bytes);
	cudaMemset(a, 0x3c, bytes);
	cudaMemset(b, 0x3c, bytes);

	auto run = [&] {
		cublasGemmEx(h, CUBLAS_OP_N, CUBLAS_OP_N, n, n, n, &alpha,
			     a, CUDA_R_16F, n, b, CUDA_R_16F, n, &beta,
			     c, CUDA_R_16F, n, CUBLAS_COMPUTE_32F,
			     CUBLAS_GEMM_DEFAULT_TENSOR_OP);
	};
	for (int i = 0; i < 10; i++)
		run();
	cudaDeviceSynchronize();

	cudaEventCreate(&t0);
	cudaEventCreate(&t1);
	cudaEventRecord(t0);
	for (int i = 0; i < iters; i++)
		run();
	cudaEventRecord(t1);
	cudaEventSynchronize(t1);
	cudaEventElapsedTime(&ms, t0, t1);

	cudaFree(a);
	cudaFree(b);
	cudaFree(c);
	return 2.0 * n * n * n * iters / (ms * 1e-3) / 1e12;
}

int main(int argc, char **argv)
{
	const char *dev_arg = "0";
	double min_tflops = 70;
	cublasHandle_t h;
	int dev;
	double last = 0;

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "-d") && i + 1 < argc)
			dev_arg = argv[++i];
		else if (!strcmp(argv[i], "--min-tflops") && i + 1 < argc)
			min_tflops = atof(argv[++i]);
		else {
			fprintf(stderr, "usage: %s [-d PCI_ADDRESS|INDEX] [--min-tflops N]\n", argv[0]);
			return 2;
		}
	}

	// A PCI address is unambiguous; a bare index follows CUDA's own ordering.
	if (strchr(dev_arg, ':')) {
		if (cudaDeviceGetByPCIBusId(&dev, dev_arg) != cudaSuccess) {
			fprintf(stderr, "no CUDA device at %s\n", dev_arg);
			return 2;
		}
	} else {
		dev = atoi(dev_arg);
	}
	if (cudaSetDevice(dev) != cudaSuccess) {
		fprintf(stderr, "cannot select device %s\n", dev_arg);
		return 2;
	}
	cublasCreate(&h);

	for (int i = 0; i < (int)(sizeof(sizes) / sizeof(sizes[0])); i++) {
		last = bench(h, sizes[i]);
		printf("%s M=N=K=%d %.1f TFLOPS\n", dev_arg, sizes[i], last);
	}
	printf("%s: %s (%.1f TFLOPS at %d, need %.1f)\n", dev_arg,
	       last >= min_tflops ? "PASS" : "FAIL", last,
	       sizes[(sizeof(sizes) / sizeof(sizes[0])) - 1], min_tflops);
	return last >= min_tflops ? 0 : 1;
}
