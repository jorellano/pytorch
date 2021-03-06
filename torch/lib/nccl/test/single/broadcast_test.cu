/*************************************************************************
 * Copyright (c) 2015-2016, NVIDIA CORPORATION. All rights reserved.
 *
 * See LICENCE.txt for license information
 ************************************************************************/

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#include "nccl.h"
#include "test_utilities.h"

int errors = 0;
double min_bw = 10000.0;
bool is_reduction = false;

template<typename T>
void RunTest(T** buff, const int N, const ncclDataType_t type, const int root,
    ncclComm_t* const comms, const std::vector<int>& dList) {
  // initialize data
  int nDev = 0;
  NCCLCHECK(ncclCommCount(comms[0], &nDev));
  cudaStream_t* s = (cudaStream_t*)malloc(sizeof(cudaStream_t)*nDev);
  T* buffer = (T*)malloc(N * sizeof(T));
  T* result = (T*)malloc(N * sizeof(T));
  memset(result, 0, N * sizeof(T));

  for (int i = 0; i < nDev; ++i) {
    CUDACHECK(cudaSetDevice(dList[i]));
    CUDACHECK(cudaStreamCreate(s+i));

    if (i == root) {
      Randomize(buff[root], N, root);
      CUDACHECK(cudaMemcpy(result, buff[root], N * sizeof(T),
          cudaMemcpyDeviceToHost));
    } else {
      CUDACHECK(cudaMemset(buff[i], 0, N * sizeof(T)));
    }

    CUDACHECK(cudaDeviceSynchronize());
  }

  // warm up GPU
  for (int i = 0; i < nDev; ++i) {
    CUDACHECK(cudaSetDevice(dList[i]));
    NCCLCHECK(ncclBcast((void*)buff[i], std::min(32 * 1024, N), type, root, comms[i], s[i]));
  }

  for (int i = 0; i < nDev; ++i) {
    CUDACHECK(cudaSetDevice(dList[i]));
    CUDACHECK(cudaStreamSynchronize(s[i]));
  }

//  for (int n = 1; n <= N; n = n << 1)
  {
    int n = N;
    printf("%12i  %12i  %6s  %4i", (int)(n * sizeof(T)), n,
        TypeName(type).c_str(), root);

    auto start = std::chrono::high_resolution_clock::now();

    for (int i = 0; i < nDev; ++i) {
      CUDACHECK(cudaSetDevice(dList[i]));
      NCCLCHECK(ncclBcast((void*)buff[i], n, type, root, comms[i], s[i]));
    }

    for (int i = 0; i < nDev; ++i) {
      CUDACHECK(cudaSetDevice(dList[i]));
      CUDACHECK(cudaStreamSynchronize(s[i]));
    }

    auto stop = std::chrono::high_resolution_clock::now();

    double elapsedSec =
        std::chrono::duration_cast<std::chrono::duration<double>>(
            stop - start).count();
    double algbw = (double)(n * sizeof(T)) / 1.0E9  / elapsedSec;
    double busbw = algbw;

    double maxDelta = 0.0;
    for (int i = 0; i < nDev; ++i) {
      CUDACHECK(cudaSetDevice(dList[i]));
      double tmpDelta = CheckDelta<T>(buff[i], result, n);
      maxDelta = std::max(tmpDelta, maxDelta);
    }

    printf("  %7.3f  %5.2f  %5.2f  %7.0le\n", elapsedSec * 1.0E3, algbw, busbw,
            maxDelta);

    if (maxDelta > deltaMaxValue(type, is_reduction)) errors++;
    if (busbw < min_bw) min_bw = busbw;
  }

  for(int i=0; i < nDev; ++i) {
    CUDACHECK(cudaSetDevice(dList[i]));
    CUDACHECK(cudaStreamDestroy(s[i]));
  }
  free(s);
  free(buffer);
  free(result);
}

template<typename T>
void RunTests(const int N, const ncclDataType_t type, ncclComm_t* const comms,
    const std::vector<int>& dList) {
  int nDev = 0;
  NCCLCHECK(ncclCommCount(comms[0], &nDev));
  T** buff = (T**)malloc(nDev * sizeof(T*));

  for (int i = 0; i < nDev; ++i) {
    CUDACHECK(cudaSetDevice(dList[i]));
    CUDACHECK(cudaMalloc(buff + i, N * sizeof(T)));
  }

  //for (int root = 1; root < 2; ++root) {
  for (int root = 0; root < nDev; ++root) {
    RunTest<T>(buff, N, type, root, comms, dList);
  }

  for (int i = 0; i < nDev; ++i) {
    CUDACHECK(cudaSetDevice(dList[i]));
    CUDACHECK(cudaFree(buff[i]));
  }

  free(buff);
}

void usage() {
  printf("Tests nccl Broadcast with user supplied arguments.\n"
      "    Usage: broadcast_test <data size in bytes> [number of GPUs] "
      "[GPU 0] [GPU 1] ...\n\n");
}

int main(int argc, char* argv[]) {
  int nVis = 0;
  CUDACHECK(cudaGetDeviceCount(&nVis));

  unsigned long long N = 0;
  if (argc > 1) {
    int t = sscanf(argv[1], "%llu", &N);
    if (t == 0) {
      printf("Error: %s is not an integer!\n\n", argv[1]);
      usage();
      exit(EXIT_FAILURE);
    }
  } else {
    printf("Error: must specify at least data size in bytes!\n\n");
    usage();
    exit(EXIT_FAILURE);
  }

  int nDev = nVis;
  if (argc > 2) {
    int t = sscanf(argv[2], "%d", &nDev);
    if (t == 0) {
      printf("Error: %s is not an integer!\n\n", argv[1]);
      usage();
      exit(EXIT_FAILURE);
    }
  }
  std::vector<int> dList(nDev);
  for (int i = 0; i < nDev; ++i)
    dList[i] = i % nVis;

  if (argc > 3) {
    if (argc - 3 != nDev) {
      printf("Error: insufficient number of GPUs in list\n\n");
      usage();
      exit(EXIT_FAILURE);
    }

    for (int i = 0; i < nDev; ++i) {
      int t = sscanf(argv[3 + i], "%d", dList.data() + i);
      if (t == 0) {
        printf("Error: %s is not an integer!\n\n", argv[2 + i]);
        usage();
        exit(EXIT_FAILURE);
      }
    }
  }

  ncclComm_t* comms = (ncclComm_t*)malloc(sizeof(ncclComm_t)*nDev);;
  NCCLCHECK(ncclCommInitAll(comms, nDev, dList.data()));

  printf("# Using devices\n");
  for (int g = 0; g < nDev; ++g) {
    int cudaDev;
    int rank;
    cudaDeviceProp prop;
    NCCLCHECK(ncclCommCuDevice(comms[g], &cudaDev));
    NCCLCHECK(ncclCommUserRank(comms[g], &rank));
    CUDACHECK(cudaGetDeviceProperties(&prop, cudaDev));
    printf("#   Rank %2d uses device %2d [0x%02x] %s\n", rank, cudaDev,
        prop.pciBusID, prop.name);
  }
  printf("\n");

  printf("# %10s  %12s  %6s  %4s  %7s  %5s  %5s  %7s\n",
      "bytes", "N", "type", "root", "time", "algbw", "busbw", "delta");

  RunTests<char>(N / sizeof(char), ncclChar, comms, dList);
  RunTests<int>(N / sizeof(int), ncclInt, comms, dList);
#ifdef CUDA_HAS_HALF
  RunTests<half>(N / sizeof(half), ncclHalf, comms, dList);
#endif
  RunTests<float>(N / sizeof(float), ncclFloat, comms, dList);
  RunTests<double>(N / sizeof(double), ncclDouble, comms, dList);
  RunTests<long long>(N / sizeof(long long), ncclInt64, comms, dList);
  RunTests<unsigned long long>(N / sizeof(unsigned long long), ncclUint64, comms, dList);

  printf("\n");

  for(int i = 0; i < nDev; ++i)
    ncclCommDestroy(comms[i]);
  free(comms);

  char* str = getenv("NCCL_TESTS_MIN_BW");
  double check_min_bw = str ? atof(str) : -1;

  printf(" Out of bounds values : %d %s\n", errors, errors ? "FAILED" : "OK");
  printf(" Min bus bandwidth    : %g %s\n", min_bw, check_min_bw == -1 ? "" : (min_bw < check_min_bw ? "FAILED" : "OK"));
  printf("\n");
  if (errors || min_bw < check_min_bw)
    exit(EXIT_FAILURE);
  else 
    exit(EXIT_SUCCESS);
}

