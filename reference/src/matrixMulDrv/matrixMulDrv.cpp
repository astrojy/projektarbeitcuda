/*
 * Copyright 1993-2009 NVIDIA Corporation.  All rights reserved.
 *
 * NVIDIA Corporation and its licensors retain all intellectual property and 
 * proprietary rights in and to this software and related documentation. 
 * Any use, reproduction, disclosure, or distribution of this software 
 * and related documentation without an express license agreement from
 * NVIDIA Corporation is strictly prohibited.
 *
 * Please refer to the applicable NVIDIA end user license agreement (EULA) 
 * associated with this source code for terms and conditions that govern 
 * your use of this NVIDIA software.
 * 
 */

/* Matrix multiplication: C = A * B.
 * Host code.
 *
 * This sample implements matrix multiplication using the CUDA driver API.
 * It has been written for clarity of exposition to illustrate various CUDA
 * programming principles, not with the goal of providing the most
 * performant generic kernel for matrix multiplication.
 *
 * CUBLAS provides high-performance matrix multiplication.
 */

// includes, system
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <math.h>

#include <iostream>
#include <cstring>

// includes, CUDA
#include <cuda.h>

// includes, project
#include <cutil_inline.h>
#include "matrixMul.h"

using namespace std;

////////////////////////////////////////////////////////////////////////////////
// declaration, forward
void runTest(int argc, char** argv);
void randomInit(float*, int);

extern "C"
void computeGold(float*, const float*, const float*, unsigned int, unsigned int, unsigned int);

static CUresult initCUDA(int argc, char **argv, CUfunction *pMatrixMul );

////////////////////////////////////////////////////////////////////////////////
// Globals
////////////////////////////////////////////////////////////////////////////////
CUdevice cuDevice;
CUcontext cuContext;
CUmodule cuModule;

////////////////////////////////////////////////////////////////////////////////
// Program main
////////////////////////////////////////////////////////////////////////////////
int
main(int argc, char** argv)
{
    runTest(argc, argv);

    cutilExit(argc, argv);
}

////////////////////////////////////////////////////////////////////////////////
//! Run a simple test for CUDA
////////////////////////////////////////////////////////////////////////////////
void
runTest(int argc, char** argv)
{
    // initialize CUDA
    CUfunction matrixMul = NULL;
    cutilDrvSafeCallNoSync(initCUDA(argc, argv, &matrixMul ));

    // set seed for rand()
    srand(2006);

    // allocate host memory for matrices A and B
    unsigned int size_A = WA * HA;
    unsigned int mem_size_A = sizeof(float) * size_A;
    float* h_A = (float*) malloc(mem_size_A);
    unsigned int size_B = WB * HB;
    unsigned int mem_size_B = sizeof(float) * size_B;
    float* h_B = (float*) malloc(mem_size_B);

    // initialize host memory
    randomInit(h_A, size_A);
    randomInit(h_B, size_B);

    // allocate device memory
    CUdeviceptr d_A;
    cutilDrvSafeCallNoSync(cuMemAlloc( &d_A, mem_size_A ));
    CUdeviceptr d_B;
    cutilDrvSafeCallNoSync(cuMemAlloc( &d_B, mem_size_B )); 

    // copy host memory to device
    cutilDrvSafeCallNoSync(cuMemcpyHtoD( d_A, h_A, mem_size_A ));
    cutilDrvSafeCallNoSync(cuMemcpyHtoD( d_B, h_B, mem_size_B ));

    // allocate device memory for result
    unsigned int size_C = WC * HC;
    unsigned int mem_size_C = sizeof(float) * size_C;
    CUdeviceptr d_C;
    cutilDrvSafeCallNoSync(cuMemAlloc(&d_C, mem_size_C));
    
    // allocate mem for the result on host side
    float* h_C = (float*) malloc(mem_size_C);

    // create and start timer
    unsigned int timer = 0;
    cutilCheckError(cutCreateTimer(&timer));
  
    // start the timer 
    cutilCheckError(cutStartTimer(timer));

    // setup execution parameters
    int offset = 0;
    void* ptr = (void*)(size_t)d_C;
    offset = (offset + __alignof(ptr) - 1) & ~(__alignof(ptr) - 1); // adjust offset for alignment requirements
    cutilDrvSafeCallNoSync(cuParamSetv( matrixMul, offset, &ptr, sizeof(ptr)));
    offset += sizeof(ptr);

    ptr = (void*)(size_t)d_A;
    offset = (offset + __alignof(ptr) - 1) & ~(__alignof(ptr) - 1); // adjust offset alignment requirements
    cutilDrvSafeCallNoSync(cuParamSetv( matrixMul, offset, &ptr, sizeof(ptr)));
    offset += sizeof(ptr);

    ptr = (void*)(size_t)d_B;
    offset = (offset + __alignof(ptr) - 1) & ~(__alignof(ptr) - 1); // adjust offset alignment requirements
    cutilDrvSafeCallNoSync(cuParamSetv( matrixMul, offset, &ptr, sizeof(ptr)));
    offset += sizeof(ptr);

    int Matrix_Width_A = WA;
    int Matrix_Width_B = WB;

    offset = (offset + __alignof(Matrix_Width_A) - 1) & ~(__alignof(Matrix_Width_A) - 1); // adjust offset alignment requirements
    cutilDrvSafeCallNoSync(cuParamSeti( matrixMul, offset, Matrix_Width_A )); offset += sizeof(Matrix_Width_A);

    offset = (offset + __alignof(Matrix_Width_B) - 1) & ~(__alignof(Matrix_Width_B) - 1); // adjust offset alignment requirements
    cutilDrvSafeCallNoSync(cuParamSeti( matrixMul, offset, Matrix_Width_B )); offset += sizeof(Matrix_Width_B);

    cutilDrvSafeCallNoSync(cuParamSetSize( matrixMul, offset ));
    cutilDrvSafeCallNoSync(cuFuncSetBlockShape( matrixMul, BLOCK_SIZE, BLOCK_SIZE, 1 ));
    cutilDrvSafeCallNoSync(cuFuncSetSharedSize( matrixMul, 2*BLOCK_SIZE*BLOCK_SIZE*sizeof(float) ) );

    // set execution configuration for the CUDA kernel
    cutilDrvSafeCallNoSync(cuLaunchGrid( matrixMul, WC / BLOCK_SIZE, HC / BLOCK_SIZE ));

    // copy result from device to host
    cutilDrvSafeCallNoSync(cuMemcpyDtoH((void *) h_C, d_C, mem_size_C) );

    // stop and destroy timer
    cutilCheckError(cutStopTimer(timer));
    printf("Processing time: %f (ms)\n", cutGetTimerValue(timer));
    cutilCheckError(cutDeleteTimer(timer));

    // compute reference solution
    float* reference = (float*) malloc(mem_size_C);
    computeGold(reference, h_A, h_B, HA, WA, WB);

    // check result
    CUTBoolean res = cutCompareL2fe(reference, h_C, size_C, 1e-6f);
    printf("Test %s\n", (1 == res) ? "PASSED" : "FAILED");

    // clean up memory
    free(h_A);
    free(h_B);
    free(h_C);
    free(reference);
    cutilDrvSafeCallNoSync(cuMemFree(d_A));
    cutilDrvSafeCallNoSync(cuMemFree(d_B));
    cutilDrvSafeCallNoSync(cuMemFree(d_C));
    cutilDrvSafeCallNoSync(cuCtxDetach(cuContext));
}

// Allocates a matrix with random float entries.
void randomInit(float* data, int size)
{
    for (int i = 0; i < size; ++i)
        data[i] = rand() / (float)RAND_MAX;
}

bool inline
findModulePath(const char * module_file, string & module_path, char **argv, string & ptx_source)
{
	FILE *fp;

    module_path = cutFindFilePath(module_file, argv[0]);
    if (module_path.empty()) {
       printf("> findModulePath could not find file: <%s> \n", module_file); 
       return false;
    } else {
       printf("> findModulePath found file at <%s>\n", module_path.c_str());

	   if (module_path.rfind(".ptx") != string::npos) {
		   fp = fopen(module_path.c_str(), "rb");
		   fseek(fp, 0, SEEK_END);
		   int file_size = ftell(fp);
		   ptx_source.reserve(file_size+512);
		   fseek(fp, 0, SEEK_SET);
		   fread(&ptx_source[0], sizeof(char), file_size, fp);
		   fclose(fp);
	   }
       return true;
    }
}

static CUresult
initCUDA(int argc, char **argv, CUfunction *pMatrixMul )
{
    CUfunction cuFunction = 0;
	int file_size = 0;
    string module_path, ptx_source;

    cutilDeviceInitDrv(cuDevice, argc, argv);
	
    CUresult status = cuCtxCreate( &cuContext, 0, cuDevice );
    if ( CUDA_SUCCESS != status )
        goto Error;

    // first search for the module path before we load the results
    if (!findModulePath ("matrixMul_kernel.ptx", module_path, argv, ptx_source)) {
       if (!findModulePath ("matrixMul_kernel.cubin", module_path, argv, ptx_source)) {
           printf("> findModulePath could not find <matrixMul_kernel> ptx or cubin\n");
           status = CUDA_ERROR_NOT_FOUND;
           goto Error;
       }
    } else {
       printf("> initCUDA loading module: <%s>\n", module_path.c_str());
    }

	if (module_path.rfind("ptx") != string::npos) {
		// in this branch we use compilation with parameters
		const unsigned int jitNumOptions = 3;
		CUjit_option *jitOptions = new CUjit_option[jitNumOptions];
		void **jitOptVals = new void*[jitNumOptions];

		// set up size of compilation log buffer
		jitOptions[0] = CU_JIT_INFO_LOG_BUFFER_SIZE_BYTES;
		int jitLogBufferSize = 1024;
		jitOptVals[0] = (void *)jitLogBufferSize;

		// set up pointer to the compilation log buffer
		jitOptions[1] = CU_JIT_INFO_LOG_BUFFER;
		char *jitLogBuffer = new char[jitLogBufferSize];
		jitOptVals[1] = jitLogBuffer;

		// set up pointer to set the Maximum # of registers for a particular kernel
		jitOptions[2] = CU_JIT_MAX_REGISTERS;
		int jitRegCount = 32;
		jitOptVals[2] = (void *)jitRegCount;

		status = cuModuleLoadDataEx(&cuModule, ptx_source.c_str(), jitNumOptions, jitOptions, (void **)jitOptVals);

		printf("> PTX JIT log:\n%s\n", jitLogBuffer);
	} else {
		status = cuModuleLoad(&cuModule, module_path.c_str());
	}

    if ( CUDA_SUCCESS != status ) {
        goto Error;
    }

    status = cuModuleGetFunction( &cuFunction, cuModule, "matrixMul" );
    if ( CUDA_SUCCESS != status )
        goto Error;
	*pMatrixMul = cuFunction;
	
    return CUDA_SUCCESS;
Error:
	cuCtxDetach(cuContext);
    return status;
}


