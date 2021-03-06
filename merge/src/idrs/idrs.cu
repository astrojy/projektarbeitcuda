#include <stdlib.h>
#include <stdio.h>

#include "projektcuda.h"

#include "kernels/sparseMatrixMul_kernel.h"
#include "kernels/dotMul_cuda_gpu.h"
#include "kernels/norm_cuda_gpu.h"
#include "kernels/gausskernel.h"

#include "bastianortho.h"

#include "kernels/matrixMul_kernel.h"

int debugmode = 0; /* No debugging as default. 1 = printf, 2=check all Operations in CPU */

typedef struct idrs_context {
    void*          devmem1stcall;
    t_SparseMatrix A;
    t_ve*          b;
    t_ve*          r;
    t_ve*          v;
    t_ve*          x;

    t_ve*          om1;
    t_ve*          om2;

} t_idrs_context;


static t_idrs_context ctxholder[4];

extern "C" void set_debuglevel( int debuglevel ) {
   debugmode = debuglevel;
};

extern "C" int get_debuglevel(  ) {
   return debugmode ;
};


extern "C" size_t idrs_sizetve() {
  return sizeof(t_ve);
}


__host__  void testortholinkcompileonly() {

    t_ve dummyRes;
    t_ve dummyP;
    orthogonalize( &dummyP, &dummyRes, 12345, 6 );
}

/* ------------------------------------------------------------------------------------- */
__global__ void kernel_vec_mul_skalar( t_ve *invec, t_ve scalar, t_ve *out, t_mindex N )
{
    t_mindex i = blockIdx.x * blockDim.x + threadIdx.x;
    if ( i < N )
        out[i] = invec[i] * scalar;
}

__host__ void dbg_vec_mul_skalar(
                              t_ve* in1_in,
                              t_ve* out1_in,
                              t_ve scalar_in,
                              t_mindex N,
                              char* debugname
                           )
{
    cudaError_t e;
    t_ve* v = (t_ve*) malloc( sizeof( t_ve ) * N );
    if (  v == NULL ) { fprintf(stderr, "sorry, can not allocate memory for you C"); exit( -1 ); }

    t_ve* vresult = (t_ve*) malloc( sizeof( t_ve ) * N );
    if (  vresult == NULL ) { fprintf(stderr, "sorry, can not allocate memory for you C"); exit( -1 ); }

    e = cudaMemcpy( v, in1_in, sizeof(t_ve) * N , cudaMemcpyDeviceToHost);
    CUDA_UTIL_ERRORCHECK("cudaMemcpy");

    e = cudaMemcpy( vresult, out1_in, sizeof(t_ve) * N , cudaMemcpyDeviceToHost);
    CUDA_UTIL_ERRORCHECK("cudaMemcpy");

    for ( t_mindex i = 0; i < N ; i++ ) {
        t_ve prod = v[i] * scalar_in;

        if ( prod  != vresult[i] ) {
            fprintf(stderr, "\n vecmul NOT OK");
            exit( -3);
        }
    }
    free( v );
    free( vresult );
}

/* ------------------------------------------------------------------------------------- */
__host__ void dbg_dump_mtx(
                             t_ve*    dv,
                             t_mindex m,
                             t_mindex n,
                             char*    mname
                          )
{


    cudaError_t e;
    t_ve* v = (t_ve*) malloc( sizeof( t_ve )  * m * n );
    if (  v == NULL ) { fprintf(stderr, "sorry, can not allocate memory for you C"); exit( -1 ); }

    e = cudaMemcpy( v, dv, sizeof(t_ve) * m * n , cudaMemcpyDeviceToHost);
    CUDA_UTIL_ERRORCHECK(" cudaMemcpy debugbuffer");

    for( t_mindex s=0; s < n; s++  ) {
        for( t_mindex r=0; r < m; r++  ) {

           t_mindex i = s * m + r;
           printf("\n %s(%u,%u)=%s[%u] = %f ",mname, r+1, s+1, mname, i, v[i] );
        }
    }

    free( v);

}
/* ------------------------------------------------------------------------------------- */

__global__ void sub_arrays_gpu( t_ve *in1, t_ve *in2, t_ve *out, t_mindex N)
{
    t_mindex i = blockIdx.x * blockDim.x + threadIdx.x;
    if ( i < N )
        out[i] = in1[i] - in2[i];

}

__global__ void add_and_mul_arrays_gpu(
                                         t_ve *in1,
                                         t_ve *in2,
                                         t_ve coefficient,
                                         t_ve *out,
                                         t_mindex N
                                        )
{
    t_mindex i = blockIdx.x * blockDim.x + threadIdx.x;
    if ( i < N )
        out[i] = in1[i] + coefficient * in2[i];

}



__global__ void add_arrays_gpu( t_ve *in1, t_ve *in2, t_ve *out, t_mindex N)
{
    t_mindex i = blockIdx.x * blockDim.x + threadIdx.x;
    if ( i < N )
        out[i] = in1[i] + in2[i];
}

__host__ size_t smat_size( int cnt_elements, int cnt_cols ) {

    return   ( sizeof(t_ve) + sizeof(t_mindex) ) * cnt_elements
           + sizeof(t_mindex)                    * (cnt_cols + 1);
}



extern "C" void idrs2nd(
    t_FullMatrix P_in,
    t_ve tolr,
    unsigned int s,
    unsigned int maxit,
    t_idrshandle ih_in, /* Context Handle we got from idrs_1st */
    t_ve* x_out,
    t_ve* resvec,
   unsigned int* piter
) {
    cudaError_t e;
    t_idrshandle ctx;


    t_FullMatrix mv;
    t_FullMatrix mr;
    t_FullMatrix mt;

    int cnt_multiprozessors;
    int deviceCount;
    cudaGetDeviceCount(&deviceCount);

    t_ve* om1;
    t_ve* om2;
    t_ve* v;

    t_mindex resveci  = 1;
    void* devmem;

    if (deviceCount == 0)
        printf("There is no device supporting CUDA\n");

    int dev;
    for (dev = 0; dev < deviceCount; ++dev) {
        cudaDeviceProp deviceProp;
        cudaGetDeviceProperties(&deviceProp, dev);
        printf("  Number of multiprocessors:                     %d\n", deviceProp.multiProcessorCount);
        cnt_multiprozessors = deviceProp.multiProcessorCount;
    }



    ctx = ih_in;

    t_SparseMatrix A         = ctxholder[ctx].A ;

    t_mindex N = A.m;

    size_t h_memblocksize =   N * sizeof( t_ve )            /* om1             */
                            + N * sizeof( t_ve )            /* om2             */
                            + N * s * sizeof( t_ve )            /* debugbuffer1    */
                            + N * sizeof( t_ve )            /* h_norm    */
                            ;

    size_t d_memblocksize =  (N*s )       * sizeof( t_ve )           /* P      */
                           + s * (s+1+1)       * sizeof( t_ve )      /* M m c    */
                           + ( N + 512 )  * sizeof( t_ve )            /* v      */
                           + (N*s )       * sizeof( t_ve )            /* dR     */
                           + (N*s )       * sizeof( t_ve )            /* dX     */

                           + (N )         * sizeof( t_ve )            /* dnormv   */
                           + (N )         * sizeof( t_ve )            /* q   */
                           + (N + 512 )   * sizeof( t_ve )            /* t   */
                           + (N + 512    ) * sizeof( t_ve )           /* buffer1   */
                           + (N + 512    ) * sizeof( t_ve )           /* dm   */
                           +  maxit * sizeof( t_ve )                  /* dm   */
//                           + (N ) * sizeof( t_ve )                  /* x   */
                      ;

    e = cudaMalloc ( &devmem , d_memblocksize );
    CUDA_UTIL_ERRORCHECK("cudaMalloc");

    e = cudaMemset (devmem, 0, d_memblocksize );
    CUDA_UTIL_ERRORCHECK("cudaMalloc");

    e = cudaMemcpy( devmem, P_in.pElement, N*s* sizeof( t_ve ) , cudaMemcpyHostToDevice);
    CUDA_UTIL_ERRORCHECK("cudaMemcpyHostToDevice");

    printf("\n additional using %u bytes in Device memory", d_memblocksize);

    t_ve* P      = (t_ve*) devmem ;
    t_ve* M      = &P[ N * s ];
    t_ve* m      = &M[ s * s ];
    t_ve* c      = &m[ s  ];
    v            = &c[ s  ];
    t_ve* dR     = &v[N + 512 ];
    t_ve* dX     = &dR[ N * s ];

    t_ve* dnormv = &dX[ N * s ];
    t_ve* q      = &dnormv[ N  ];
    t_ve* t      = &q[ N  ];
    t_ve* buffer1 = &t[N + 512 ];
    t_ve* dm      = &buffer1[N + 512 ];

    t_ve* x          = ctxholder[ctx].x;

    void* hostmem =   malloc( h_memblocksize );
    if ( hostmem == NULL ) { fprintf(stderr, "sorry, can not allocate memory for you hostmem"); exit( -1 ); }

    t_ve*  h_om1        = (t_ve*) hostmem;
    t_ve*  h_om2        = &h_om1[N];
    t_ve*  debugbuffer1 = &h_om2[N];
    t_ve*  h_norm        = &debugbuffer1[N*s];

    t_ve norm;


    mr.m        = A.m;
    mr.n        = 1;
    mr.pElement = ctxholder[ctx].r;

    mt.m        = A.m;
    mt.n        = 1;
    mt.pElement = t;


    t_ve* r = mr.pElement;

    mv.m        = A.m;
    mv.n        = 1;
    mv.pElement = v ;

    om1 = ctxholder[ctx].om1;
    om2 = ctxholder[ctx].om2;

    dim3 dimGrid ( cnt_multiprozessors );

    dim3 dimGrids( s );
    dim3 dimGridN( N );
    dim3 dimBlock(512);
    dim3 dimGridsub( A.m / 512 + 1 );

    dim3 dimGridgauss( 1 );
    dim3 dimBlockgauss(512);

//    t_ve som ;


    //dbg_dump_mtx( dX,N,s, "dX" );
    //dbg_dump_mtx( dR,N,s, "dR" );
    //dbg_dump_mtx( P,s,N, "P" );
    //dbg_dump_mtx( r,N,1, "r" );
    //dbg_dump_mtx( x,N,1, "x" );

    //if ( debugmode > 0 ) { printf("\n DEBUGMODE %u - starting L1", debugmode ); }

    for ( t_mindex k = 1; k <= s; k++ ) {

        t_ve* dR_k = &dR[ N * (k-1) ];
        t_ve* dX_k = &dX[ N * (k-1) ];



//        e = cudaMemset (v, 0, sizeof(t_ve) * N );
//        CUDA_UTIL_ERRORCHECK("cudaMemset");

        /* 22 v = A*r; */
        //sparseMatrixMul<<<dimGrid,dimBlock>>>( mt, A, mv ); e = cudaGetLastError(); CUDA_UTIL_ERRORCHECK("sparseMatrixMul<<<dimGrid,dimBlock>>>( mt, A, mv )");

        sparseMatrixMul<<<dimGrid,dimBlock>>>( mv, A, mr );   e = cudaGetLastError();  CUDA_UTIL_ERRORCHECK("testsparseMatrixMul");



        e = cudaStreamSynchronize(0);
        CUDA_UTIL_ERRORCHECK("cudaStreamSynchronize(0)");

        //dbg_dump_mtx( v,N,1, "v" );
        //dbg_dump_mtx( r,N,1, "r" );

        kernel_dotmul<<<dimGridsub,dimBlock>>>( v, r, om1 ) ;  e = cudaGetLastError();  CUDA_UTIL_ERRORCHECK("device_dotMul");

        kernel_dotmul<<<dimGridsub,dimBlock>>>( v, v, om2 ) ;  e = cudaGetLastError(); CUDA_UTIL_ERRORCHECK("device_dotMul");

        e = cudaStreamSynchronize(0); CUDA_UTIL_ERRORCHECK("cudaStreamSynchronize(0)");

//        if ( debugmode > 0 ) { printf("\n DEBUGMODE %u - L1, k = %u, after Dotmul", debugmode, k ); }

        e = cudaMemcpy( h_om1, om1, sizeof(t_ve) * N * 2, cudaMemcpyDeviceToHost);   CUDA_UTIL_ERRORCHECK("cudaMemcpy( h_om1, om1, sizeof(t_ve) * N * 2, cudaMemcpyDeviceToHost)");

        t_ve om;
        t_ve  som1 = 0;
        t_ve  som2 = 0;
        for ( t_mindex blockidx = 0; blockidx < A.m / 512 + 1; blockidx++ ) {
            som1 += h_om1[blockidx];
            som2 += h_om2[blockidx];
        }
        om = som1 / som2;

        if( debugmode > 1 ) { dbg_dotmul_checkresult( v, r, som1, N, "loop1, som1"); };
        if( debugmode > 1 ) { dbg_dotmul_checkresult( v, v, som2, N, "loop1, som2"); };

        kernel_vec_mul_skalar<<<dimGridsub,dimBlock>>>( mr.pElement,   om , dX_k, N ); e = cudaGetLastError(); CUDA_UTIL_ERRORCHECK("kernel_vec_mul_skalar<<<dimGridsub,dimBlock>>>( mr.pElement,   som , dX_k, N )");


        if( debugmode > 1 ) {  dbg_vec_mul_skalar( r, dX_k, om, N, "mr.pElement,   om , dX_k, N" ); }


        kernel_vec_mul_skalar<<<dimGridsub,dimBlock>>>( mv.pElement, - om , dR_k, N ); e = cudaGetLastError(); CUDA_UTIL_ERRORCHECK("kernel_vec_mul_skalar<<<dimGridsub,dimBlock>>>( mv.pElement, - som , dR_k, N )");
        if( debugmode > 1 ) { dbg_vec_mul_skalar( v, dR_k, -1 * om, N, "mv.pElement, - om , dR_k, N" ); }


        e = cudaStreamSynchronize(0);
        CUDA_UTIL_ERRORCHECK("cudaStreamSynchronize(0)");

        add_arrays_gpu<<<dimGridsub,dimBlock>>>( x, dX_k, x, N ); e = cudaGetLastError(); CUDA_UTIL_ERRORCHECK("add_arrays_gpu<<<dimGridsub,dimBlock>>>( x, dX_k, x, N )");

        add_arrays_gpu<<<dimGridsub,dimBlock>>>( r, dR_k, r, N );  e = cudaGetLastError();  CUDA_UTIL_ERRORCHECK("add_arrays_gpu<<<dimGridsub,dimBlock>>>( mr.pElement, dR_k, mr.pElement, N );");


        /* 26 normr = norm(r) */
        e = cudaMemset (dnormv, 0, sizeof(t_ve) * N );
        CUDA_UTIL_ERRORCHECK("cudaMemset");
        kernel_norm<<<dimGridsub,dimBlock>>>( mr.pElement, dnormv );  e = cudaGetLastError();  CUDA_UTIL_ERRORCHECK("kernel_norm<<<dimGridsub,dimBlock>>>( mr.pElement, dnormv )");

        //dbg_dump_mtx( dnormv,N,1, "dnormv" );

        e = cudaMemcpy( h_norm, dnormv, sizeof(t_ve) * N , cudaMemcpyDeviceToHost);
        CUDA_UTIL_ERRORCHECK(" cudaMemcpy debugbuffer");

        t_ve snorm = 0;
        for ( t_mindex i = 0; i < N / 512 + 1 ; i++ ) {
             snorm +=  h_norm[i];
        }
        norm = sqrt(snorm);
        if( debugmode > 1 ) { dbg_norm_checkresult( r, norm , N, "loop1, norm"); }
        resvec[ resveci++ ]  = norm;

        /* 28    M(:,k) = P*dR(:,k); */

        t_ve* Mk = &M[ s * (k-1) ];

        matrixMul<<<dimGrids,dimBlock>>>( Mk, P, dR_k , s, N );       e = cudaGetLastError();  CUDA_UTIL_ERRORCHECK("matrixMul<<<dimGrid,dimBlock>>>( P, r , m, s, 1 )");
        //matrixMul_long_mA<<<dimGrids,dimBlock>>>( Mk, P, dR_k , s, N );       e = cudaGetLastError();  CUDA_UTIL_ERRORCHECK("matrixMul<<<dimGrid,dimBlock>>>( P, r , m, s, 1 )");
        if( debugmode > 1 ) { dbg_matrixMul_checkresult( Mk, P, dR_k , s, N, "28    M(:,k) = P*dR(:,k);" ); }

        if( debugmode > 0 ) { printf("\n L1 k=%u, norm = %f   1 %f   2 %f", k, norm, som1, som2 ); }

        e = cudaStreamSynchronize(0);
        CUDA_UTIL_ERRORCHECK("cudaStreamSynchronize(0)");
    }
    //dbg_dump_mtx( dX,N,s, "dX" );
    //dbg_dump_mtx( dR,N,s, "dR" );
    //dbg_dump_mtx( M,s,s, "M" );

    t_mindex iter   = s; /* iter.m line 31 */
    t_mindex oldest = 0; /* iter.m line 32 */


    /*  33   m = P* r    */

    matrixMul<<<dimGrids,dimBlock>>>( m, P, r , s, N );   e = cudaGetLastError(); CUDA_UTIL_ERRORCHECK("matrixMul<<<dimGrid,dimBlock>>>( P, r , m, s, 1 )");
    if( debugmode > 1 ) { dbg_matrixMul_checkresult( m, P, r , s, N, " 33   m = P* r " ) ; }


    while (  (norm > tolr ) && ( iter < maxit )  ) {
        for ( t_mindex k = 0; k <= s; k++ ) {

           t_ve om;

           t_ve* dRoldest = &dR[ oldest  * N ];
           t_ve* dXoldest = &dX[ oldest  * N ];
//sgstag
           /* 36 c = M\n  iter.m line 36 */
           device_gauss_solver<<<dimGridgauss,dimBlockgauss>>>( M, s, c ); /* vec m is s+1 column of M - see memory allocation plan  */
           e = cudaGetLastError();  CUDA_UTIL_ERRORCHECK("device_gauss_solver<<<dimGridgauss,dimBlockgauss>>>( M, s, c )");

           if( debugmode > 1 ) { dbg_solver_check_result( M, s, c ); }

           /* 37  q = -dR * c */
//           if ( N > 2000 ) {
               matrixMul_long_mA<<<dimGrid,dimBlock>>>( q, dR , c, N, s );    e = cudaGetLastError();  CUDA_UTIL_ERRORCHECK("matrixMul<<<dimGridgauss,dimBlockgauss>>>( q, dR , c, N, 1 )");
//           }
//           else {
//               matrixMul<<<dimGridN,dimBlock>>>( q, dR , c, N, s );    e = cudaGetLastError();  CUDA_UTIL_ERRORCHECK("matrixMul<<<dimGridgauss,dimBlockgauss>>>( q, dR , c, N, 1 )");
//           }

           if( debugmode > 1 ) { dbg_matrixMul_checkresult( q, dR , c, N, s, "37  q = -dR * c " ); }

           kernel_vec_mul_skalar<<<dimGridsub,dimBlock>>>( q, -1 , q, N );  e = cudaGetLastError();  CUDA_UTIL_ERRORCHECK("kernel_vec_mul_skalar<<<dimGridsub,dimBlock>>>( mv.pElement, - som , dR_k, N )");

           /* 38 v = r + q */
           add_arrays_gpu<<<dimGridsub,dimBlock>>>( r, q, v, N );  e = cudaGetLastError();  CUDA_UTIL_ERRORCHECK("add_arrays_gpu<<<dimGridsub,dimBlock>>>( x, dX_k, x, N )");

           if ( k == 0 ) {

               /* 40   t = A*v  idrs.m */
               e = cudaMemset (t, 0, sizeof(t_ve) * N );
               CUDA_UTIL_ERRORCHECK("cudaMalloc");
               sparseMatrixMul<<<dimGrid,dimBlock>>>( mt, A, mv ); e = cudaGetLastError(); CUDA_UTIL_ERRORCHECK("sparseMatrixMul<<<dimGrid,dimBlock>>>( mt, A, mv )");

        e = cudaStreamSynchronize(0);
        CUDA_UTIL_ERRORCHECK("cudaStreamSynchronize(0)");

               kernel_dotmul<<<dimGridsub,dimBlock>>>( t, v, om1 ) ; e = cudaGetLastError(); CUDA_UTIL_ERRORCHECK("device_dotMul");
               kernel_dotmul<<<dimGridsub,dimBlock>>>( t, t, om2 ) ; e = cudaGetLastError(); CUDA_UTIL_ERRORCHECK("device_dotMul");

               e = cudaStreamSynchronize(0); CUDA_UTIL_ERRORCHECK("cudaStreamSynchronize(0)");

               e = cudaMemcpy( h_om1, om1, sizeof(t_ve) * N * 2, cudaMemcpyDeviceToHost); CUDA_UTIL_ERRORCHECK("cudaMemcpy( h_om1, om1, sizeof(t_ve) * N * 2, cudaMemcpyDeviceToHost)");

               t_ve  som1 = 0;
               t_ve  som2 = 0;
               for ( t_mindex blockidx = 0; blockidx < A.m / 512 + 1; blockidx++ ) {
                    som1 += h_om1[blockidx];
                    som2 += h_om2[blockidx];
                    //printf("\n h_om1[%u] = %f ", blockidx, h_om1[blockidx] );
               }
               om = som1 / som2;

               if( debugmode > 1 ) { dbg_dotmul_checkresult( t, v, som1, N, "loop2, som1"); }
               if( debugmode > 1 ) { dbg_dotmul_checkresult( t, t, som2, N, "loop2, som2"); }

                if( debugmode > 0 ) { printf("\n L2 k = %u om = %f  om=%f om2=%f", k, om, som1, som2   ); }

               /*  42            dR(:,oldest) = q - om*t; % 1 update */
               add_and_mul_arrays_gpu<<<dimGridsub,dimBlock>>>( q, t, -om, dRoldest , N);  e = cudaGetLastError();  CUDA_UTIL_ERRORCHECK("sub_and_mul_arrays_gpu");

               /*  43    dX(:,oldest) = -dX*c + om*v; % s updates + 1 scaling */
               matrixMul_long_mA<<<dimGrid,dimBlock>>>( buffer1, dX, c , N, s ); e = cudaGetLastError(); CUDA_UTIL_ERRORCHECK("matrixMul<<<dimGrid,dimBlock>>>( dX, c , dXoldest, N, 1 )");

               if( debugmode > 1 ) { dbg_matrixMul_checkresult( buffer1, dX, c , N, s, "43    dX(:,oldest) = -dX*c + om*v; % s updates + 1 scaling" ); }

               kernel_vec_mul_skalar<<<dimGridsub,dimBlock>>>( buffer1, -1 , buffer1, N );  e = cudaGetLastError();  CUDA_UTIL_ERRORCHECK("kernel_vec_mul_skalar<<<dimGridsub,dimBlock>>>( mv.pElement, - som , dR_k, N )");

               add_and_mul_arrays_gpu<<<dimGridsub,dimBlock>>>( buffer1, v, om, dXoldest , N);   e = cudaGetLastError();  CUDA_UTIL_ERRORCHECK("add_and_mul_arrays_gpu");

               //if( debugmode > 0 ) { printf("\n k = %u om = %f  om1=%f om2=%f", k, om, som1, som2   ); }

           }
           else {

               t_FullMatrix mdRoldest;
               t_FullMatrix mdXoldest;

               mdRoldest.m        = 1;
               mdRoldest.n        = N;
               mdRoldest.pElement = dRoldest;

               mdXoldest.m        = 1;
               mdXoldest.n        = N;
               mdXoldest.pElement = dXoldest;


               /*  45    dX(:,oldest) = -dX*c + om*v; % s updates + 1 scaling */
                matrixMul_long_mA<<<dimGrid,dimBlock>>>( buffer1, dX, c , N, s );  e = cudaGetLastError(); CUDA_UTIL_ERRORCHECK("matrixMul<<<dimGrid,dimBlock>>>( dX, c , dXoldest, N, 1 )");

               if( debugmode > 1 ) { dbg_matrixMul_checkresult( buffer1, dX, c , N, s, "45    dX(:,oldest) = -dX*c + om*v"); }

               kernel_vec_mul_skalar<<<dimGridsub,dimBlock>>>( buffer1, -1 , buffer1, N );  e = cudaGetLastError();  CUDA_UTIL_ERRORCHECK("kernel_vec_mul_skalar<<<dimGridsub,dimBlock>>>( mv.pElement, - som , dR_k, N )");

               add_and_mul_arrays_gpu<<<dimGridsub,dimBlock>>>( buffer1, v, om, dXoldest , N); e = cudaGetLastError(); CUDA_UTIL_ERRORCHECK("add_and_mul_arrays_gpu");


              /* 46  dR(:,oldest) = -A*dX(:,oldest); % 1 matmul */

               e = cudaMemset (mdRoldest.pElement, 0, sizeof(t_ve) * N );
               CUDA_UTIL_ERRORCHECK("cudaMalloc");
               sparseMatrixMul<<<dimGrid,dimBlock>>>( mdRoldest, A, mdXoldest );  e = cudaGetLastError();  CUDA_UTIL_ERRORCHECK("sparseMatrixMul<<<dimGrid,dimBlock>>>( mt, A, mv )");

               kernel_vec_mul_skalar<<<dimGridsub,dimBlock>>>( dRoldest, -1 , dRoldest, N );  e = cudaGetLastError();  CUDA_UTIL_ERRORCHECK("kernel_vec_mul_skalar<<<dimGridsub,dimBlock>>>( mv.pElement, - som , dR_k, N )");
           }

           /*  48      r = r + dR(:,oldest); % simple addition */

           add_arrays_gpu<<<dimGridsub,dimBlock>>>( r, dRoldest, r, N ); e = cudaGetLastError(); CUDA_UTIL_ERRORCHECK("add_arrays_gpu<<<dimGridsub,dimBlock>>>( r, dRoldest, r, N )");

           /*  49 x = x + dX(:,oldest); % simple addition */

           add_arrays_gpu<<<dimGridsub,dimBlock>>>( x, dXoldest, x, N ); e = cudaGetLastError(); CUDA_UTIL_ERRORCHECK("add_arrays_gpu<<<dimGridsub,dimBlock>>>( r, dRoldest, r, N )");
           iter++;


           e = cudaMemset (dnormv, 0, sizeof(t_ve) * N );
           CUDA_UTIL_ERRORCHECK("cudaMalloc");

           kernel_norm<<<dimGridsub,dimBlock>>>( r, dnormv ); e = cudaGetLastError(); CUDA_UTIL_ERRORCHECK("kernel_norm<<<dimGridsub,dimBlock>>>( mr.pElement, dnormv )");
           e = cudaMemcpy( h_norm, dnormv, sizeof(t_ve) * N , cudaMemcpyDeviceToHost); CUDA_UTIL_ERRORCHECK(" cudaMemcpy debugbuffer");

            t_ve snorm = 0;
            for ( t_mindex i = 0; i < N / 512 + 1 ; i++ ) {
                 snorm +=  h_norm[i];
            }
            norm = sqrt( snorm ); resvec[ resveci++ ]  =  norm ;

            if( debugmode > 1  ) { dbg_norm_checkresult( r, norm , N, "loop2, norm"); }
            if( debugmode > 0 )  { printf( "\n L2 iteration %u k=%u, oldest=%u, norm %f", iter, k, oldest,  norm ); }

            /* 53 dm = P*dR(:,oldest); % s inner products */
            t_ve* Moldest = &M[ s * oldest ];

            dm = Moldest;

            e = cudaStreamSynchronize(0);
            CUDA_UTIL_ERRORCHECK("cudaStreamSynchronize(0)");

            matrixMul<<<dimGrids,dimBlock>>>( Moldest, P, dRoldest ,  s, N );   e = cudaGetLastError();  CUDA_UTIL_ERRORCHECK("matrixMul<<<dimGrid,dimBlock>>>( P, dRoldest , Moldest, s, 1 )");

            e = cudaStreamSynchronize(0);
            CUDA_UTIL_ERRORCHECK("cudaStreamSynchronize(0)");

            if( debugmode > 1  ) { dbg_matrixMul_checkresult( Moldest, P, dRoldest ,  s, N, "53 dm = P*dR(:,oldest)" ); }

            /* 55  m = m + dm; */
            add_arrays_gpu<<<dimGridgauss,dimBlock>>>( m, dm, m, s );  e = cudaGetLastError();  CUDA_UTIL_ERRORCHECK("add_arrays_gpu<<<dimGridsub,dimBlock>>>( r, dRoldest, r, N )");

            oldest++;
            if ( oldest > s - 1 ) {
               oldest = 0 ;
            }
        }

    }
    *piter = iter;


    e = cudaMemcpy( x_out, x, sizeof(t_ve) * N , cudaMemcpyDeviceToHost);
    CUDA_UTIL_ERRORCHECK("cudaMemcpy");

    e = cudaFree( devmem );
    CUDA_UTIL_ERRORCHECK("e = cudaFree( devmem );");

    e = cudaFree( ctxholder[ctx].devmem1stcall );
    CUDA_UTIL_ERRORCHECK("cudaFree ctxholder[ctx].devmem1stcall ");

   free( hostmem );
}


/*
__global__ void testsparseMatrixMul( t_FullMatrix pResultVector,t_SparseMatrix pSparseMatrix, t_FullMatrix b ) {

    t_mindex tix = blockIdx.x * blockDim.x + threadIdx.x;
    if ( tix  < pSparseMatrix.m ) {
        //printf ( "\n block %u thread %u tix %u N %u", blockIdx.x, threadIdx.x, tix, pSparseMatrix.m );
        //printf("\n %u %f", tix, b.pElement[tix] );
        pResultVector.pElement[tix] = b.pElement[tix] - 1;
    }
    if ( tix == 0 ) {
        for ( t_mindex i = 0; i < pSparseMatrix.m + 1 ; i++ ) {
             printf("\n pRow[%u] =  %u", i, pSparseMatrix.pRow[i] );
        }
        for ( t_mindex i = 0; i < pSparseMatrix.nzmax ; i++ ) {
            printf("\n pNZElement[%u] =  %f", i, pSparseMatrix.pNZElement[i] );
        }
        for ( t_mindex i = 0; i < pSparseMatrix.nzmax ; i++ ) {
            printf("\n pCol[%u] =  %u", i, pSparseMatrix.pCol[i] );
        }
    }

}
*/

__host__ void set_sparse_data( t_SparseMatrix A_in, t_SparseMatrix* A_out, void* mv ) {

    A_out->m     = A_in.m;
    A_out->n     = A_in.n;
    A_out->nzmax = A_in.nzmax;


    A_out->pNZElement = (t_ve *)     mv ;

    A_out->pCol       = (t_mindex *)  &A_out->pNZElement[ A_out->nzmax ];
    A_out->pRow       = (t_mindex *) (&A_out->pCol[A_out->nzmax]);

//    A_out->pCol       = (t_mindex *)  mv;
//    A_out->pNZElement = (t_ve *)     (&A_out->pCol[A_out->nzmax] ) ;
//    A_out->pRow       = (t_mindex *) (&A_out->pNZElement[A_out->nzmax]);

}

extern "C" void idrs_1st(

                     t_SparseMatrix A_in,    /* A Matrix in buyu-sparse-format */
                     t_ve*          b_in,    /* b as in A * b = x */
                     t_ve*          xe_in,
                     t_mindex N,

                     t_ve*          r_out,    /* the r from idrs.m line 6 : r = b - A*x; */

                     t_idrshandle*  ih_out,  /* handle for haloding all the device pointers between matlab calls */

                     t_ve*        resvec_out
           ) {



    t_idrshandle ctx;

    cudaError_t e;
    size_t h_memblocksize;
    size_t d_memblocksize;

    t_SparseMatrix A_d;

    t_ve* d_tmpAb;
    t_ve* d_b;
    t_ve* d_xe;
    t_ve* d_r;
    t_ve* xe;

    void *hostmem;
    void *devmem;

    ctx = 0;

    int cnt_multiprozessors;
    int deviceCount;
    cudaGetDeviceCount(&deviceCount);

    if (deviceCount == 0)
        printf("There is no device supporting CUDA\n");

    int dev;
    for (dev = 0; dev < deviceCount; ++dev) {
        cudaDeviceProp deviceProp;
        cudaGetDeviceProperties(&deviceProp, dev);
        printf("  Number of multiprocessors:                     %d\n", deviceProp.multiProcessorCount);
        cnt_multiprozessors = deviceProp.multiProcessorCount;
    }


    h_memblocksize =   smat_size( A_in.nzmax, A_in.m )  /* A sparse     */
                     + ( N + 512 ) * sizeof( t_ve )     /* b full       */
                     + N * sizeof( t_ve )               /* xe           */
                     ;

    d_memblocksize =  h_memblocksize
                    + (N + 512) * sizeof( t_ve )            /* d_tmpAb         */
                    + (N + 512) * sizeof( t_ve )            /* d_r             */
                    + N * sizeof( t_ve )            /* om1             */
                    + N * sizeof( t_ve )            /* om2             */
                    + N * sizeof( t_ve )            /* x               */

                    + N * sizeof( t_ve )            /* normv           */

                      ;

    printf("\n using N = %u (full vector size )", N );
    printf("\n using %u bytes in Host   memory", h_memblocksize);
    printf("\n using %u bytes in Device memory", d_memblocksize);



    hostmem =   malloc( h_memblocksize );
    memset(hostmem, 0, h_memblocksize);
    if ( hostmem == NULL ) { fprintf(stderr, "sorry, can not allocate memory for you hostmem"); exit( -1 ); }

/*
      pcol       |  t_mindex  |  .nzmax
      pNZElement |  t_ve      |  .nzmax
      pRow       |  t_mindex  |  N
      b          |  t_ve      |  N
      d_xe       |  t_ve      |  N
      d_tmpAb    |  t_ve      |  N
      d_r        |  t_ve      |  N
      d_om1      |  t_ve      |  N
      d_om2      |  t_ve      |  N

*/

    /* copy all parameter vectors to ony monoliythic block starting at hostmem */



    t_ve* b = (t_ve *) hostmem;
    memcpy( b, b_in,  N *  sizeof(t_ve) );

    xe = (t_ve *) &b[N + 512];
    memcpy( xe, xe_in,  N *  sizeof(t_ve) );


    t_ve* pNZElement =  (t_ve *) &xe[N] ;
    memcpy( pNZElement, A_in.pNZElement, A_in.nzmax *  sizeof(t_ve) );

    t_mindex *pcol = (t_mindex *) &pNZElement[A_in.nzmax];
    memcpy( pcol, A_in.pCol, A_in.nzmax * sizeof(t_mindex) );


    t_mindex* pRow = (t_mindex *) (&pcol[A_in.nzmax]);
    memcpy( pRow, A_in.pRow, ( A_in.m + 1 ) *  sizeof(t_mindex) );


    e = cudaMalloc ( &devmem , d_memblocksize );
    CUDA_UTIL_ERRORCHECK("cudaMalloc")

    e = cudaMemset (devmem, 0, d_memblocksize );
    CUDA_UTIL_ERRORCHECK("cudaMemset");







    d_tmpAb = (pt_ve) devmem;
    d_r     = (t_ve *) &d_tmpAb[ N + 512 ];

    ctxholder[ctx].om1 = (t_ve *) &d_r[N + 512 ];
    ctxholder[ctx].om2 = (t_ve *) &ctxholder[ctx].om1[N];

    t_ve* normv        = (t_ve *) &ctxholder[ctx].om2[N];

    pt_ve devinputmem = &normv[N];

//    set_sparse_data(  A_in, &A_d, devinputmem );
    d_b     = (t_ve *) devinputmem ;
    d_xe    = (t_ve *) &d_b[N + 512 ];
    set_sparse_data(  A_in, &A_d, &d_xe[N] );


    e = cudaMemcpy( devinputmem, hostmem, h_memblocksize , cudaMemcpyHostToDevice);
    CUDA_UTIL_ERRORCHECK("cudaMemcpyHostToDevice");

    free(hostmem);


    dim3 dimGrid ( cnt_multiprozessors );
    dim3 dimGridsub( N / 512 + 1 );
    dim3 dimBlock(512);

    /* --------------------------------------------------------------------- */

    t_FullMatrix mxe;
    t_FullMatrix result;

    mxe.m        = N;
    mxe.n        = 1;
    mxe.pElement = d_xe;

    result.pElement = d_tmpAb;
    result.m    = N ;
    result.n    = 1;
    //testsparseMatrixMul<<<dimGrid,dimBlock>>>( result, A_d, mb );
    sparseMatrixMul<<<dimGrid,dimBlock>>>( result, A_d, mxe );
    e = cudaGetLastError();
    CUDA_UTIL_ERRORCHECK("testsparseMatrixMul");


//   add_arrays_gpu( t_ve *in1, t_ve *in2, t_ve *out, t_mindex N)
    sub_arrays_gpu<<<dimGridsub,dimBlock>>>( d_b, d_tmpAb, d_r, N);
    e = cudaGetLastError();
    CUDA_UTIL_ERRORCHECK("sub_arrays_gpu");
    /* --------------------------------------------------------------------- */
    e = cudaMemcpy( r_out, d_r, sizeof(t_ve) * N, cudaMemcpyDeviceToHost);
    CUDA_UTIL_ERRORCHECK("cudaMemcpyDeviceToHost");

    /* 7  normr = norm(r);  */

    if ( debugmode > 0 ) { printf("\n %s %u: dimGridsub = %u", __FILE__, __LINE__, dimGridsub.x ); }
    kernel_norm<<<dimGridsub,dimBlock>>>( d_r, normv );  e = cudaGetLastError();  CUDA_UTIL_ERRORCHECK("kernel_norm<<<dimGridsub,dimBlock>>>( mr.pElement, dnormv )");

    t_ve* h_norm = (t_ve*) malloc( sizeof( t_ve ) * N );
    if (  h_norm == NULL ) { fprintf(stderr, "sorry, can not allocate memory for you B"); exit( -1 ); }

    e = cudaMemcpy( h_norm, normv, sizeof(t_ve) * N, cudaMemcpyDeviceToHost);
    CUDA_UTIL_ERRORCHECK("cudaMemcpyDeviceToHost");

    t_ve snorm = 0;
    for ( t_mindex i = 0; i < N / 512 + 1 ; i++ ) {
             snorm +=  h_norm[i];
    }
    t_ve norm = sqrt(snorm);

    //dbg_dump_mtx( d_b,N + 10,1, "b" );
    //dbg_dump_mtx( normv,N,1, "normv" );

    if( debugmode > 1 ) { dbg_norm_checkresult( d_r, norm , N, "1st norm for scaling, norm"); }



    /* 9  */

    resvec_out[0] = norm;

    if ( debugmode > 0 ) { printf("\n %s %u: trying free", __FILE__, __LINE__ ); }
    free(h_norm);
    if ( debugmode > 0 ) { printf("\n %s %u: sucessfull free", __FILE__, __LINE__ ); }

    ctxholder[ctx].devmem1stcall = devmem;
    ctxholder[ctx].A             = A_d;
    ctxholder[ctx].b             = d_b;
    ctxholder[ctx].r             = d_r;
    ctxholder[ctx].v             = d_tmpAb; /* memory reusage */
    ctxholder[ctx].x             = d_xe;

    *ih_out = ctx;  /* context handle for later use in later calls */

}  /* end idrs1st */


extern "C" void idrswhole(

    t_SparseMatrix A_in,    /* A Matrix in buyu-sparse-format */
    t_ve*          b_in,    /* b as in A * b = x */

    t_mindex s,
    t_ve tol,
    t_mindex maxit,

    t_ve*          x0_in,

    t_mindex N,

    t_ve* x_out,
    t_ve* resvec_out,
    unsigned int* piter

) {

    t_ve* r;
    t_idrshandle irdshandle;


    t_FullMatrix P;

    t_ve* P_init;
    t_ve* P_ortho;
    t_ve* P_transp;

    r = ( t_ve* ) malloc( sizeof( t_ve ) *  N );
    if ( r == NULL) { fprintf(stderr, "sorry, can not allocate memory for you b"); exit( -1 ); }

    P_init = ( t_ve* ) malloc( sizeof( t_ve ) *  N * s * 3 );
    if ( P_init == NULL) { fprintf(stderr, "sorry, can not allocate memory for you b"); exit( -1 ); }
    P_ortho = &P_init[ N * s ];
    P_transp = &P_ortho[ N * s ];

    printf("\n this is debugmode %u \n", debugmode);



    idrs_1st( A_in, b_in, x0_in, N, r,  &irdshandle, resvec_out );

    orthogonalize( P_init, r, N, s );

    for ( t_mindex i = 1; i <= N; i++ ) {
        for ( t_mindex j = 1; j <= s; j++ ) {
            P_transp[ as(j, i) ] = P_init[ a(i, j) ];
        }
    }

//    for (int i = 0; i < N *s; i++ )  {
//       printf("\n P_transp[%u]=%f", i, P_transp[i]);
//    }

    P.m = s;
    P.n = N;
    P.pElement = P_transp;
    idrs2nd(
       P,
       tol * resvec_out[0],        /* tolr = tol * norm(b) */
       s,          /* s - as discussed with Bastian on 2010-01-27 */
       maxit,
       irdshandle, /* Context Handle we got from idrs_1st */
       x_out,
       resvec_out,
       piter
   );




    free(r);
    free(P_init);
}
