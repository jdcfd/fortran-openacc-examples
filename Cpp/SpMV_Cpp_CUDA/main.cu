/*
Author: Juan D. Colmenares F.
User  : jdcfd@github.com

Sparse Matrix-Vector multiplication in CUDA

Reads in Sparse matrix in MatrixMarket COO format and multiplies
it by a dense vector with random values.

*/
#include <helper_cuda.h>
#include <matrix.hpp>
#include <matrix_csr.cuh>
#include <mmio_reader.cuh>
#include <vector_dense.cuh>
#include <cusparse.h> 

#define EPS 1e-14

#define CHECK_CUSPARSE(func)                                                   \
{                                                                              \
    cusparseStatus_t status = (func);                                          \
    if (status != CUSPARSE_STATUS_SUCCESS) {                                   \
        printf("CUSPARSE API failed at line %d with error: %s (%d)\n",         \
               __LINE__, cusparseGetErrorString(status), status);              \
        return EXIT_FAILURE;                                                   \
    }                                                                          \
}

using namespace std;

template <int block_size>
__global__ void sparse_mvm(int * rows, int * cols, double * vals, double * vec, double * res, int nrows, int ncols)
{
    // Block index
    int row = threadIdx.y + blockDim.y*blockIdx.x;
    if(row < nrows){
        int start {rows[row]};
        int end {rows[row+1]}; 
        double sum = 0.0;

        for(int icol = threadIdx.x + start; icol < end; icol += block_size ){
            sum += vals[icol] * vec[cols[icol]];
        }

        // Need to use templated block size to unroll loop
#pragma unroll
        for (int i = block_size >> 1; i > 0; i >>= 1)
            sum += __shfl_down_sync(0xffffffff,sum, i, i*2);

        if(!threadIdx.x){ res[row] = sum; } // write only with first thread        
    }
}

/*
template <int block_size>
__global__ void sparse_mvm_shared(int * rows, int * cols, double * vals, double * vec, double * res, int nrows, int ncols)
{
    // Block index
    int row = threadIdx.y + blockDim.y*blockIdx.x;
    double shared [block_size];
    if(row < nrows){
        int start {rows[row]};
        int end {rows[row+1]}; 
        double sum = 0.0;

        for(int icol = threadIdx.x + start; icol < end; icol += block_size ){
            sum += vals[icol] * vec[cols[icol]];
        }

        // Need to use templated block size to unroll loop
#pragma unroll
        for (int i = block_size >> 1; i > 0; i >>= 1)
            sum += __shfl_down_sync(0xffffffff,sum, i, block_size);

        if(!threadIdx.x){ res[row] = sum; } // write only with first thread        
    }
}
*/

void run_test(CSRMatrix *mymat, DenseVector *X, DenseVector *Y, int mnnzpr){
    // limit the number of threads per row to be no larger than the warp size
    int block_size {32};
    while(block_size > mnnzpr){
        block_size >>= 1;
    }

    int rows_per_block = 1024 / block_size;
    int num_blocks = (mymat->nrows + rows_per_block - 1) / rows_per_block;
    
    dim3 blocks(num_blocks, 1, 1);
    dim3 threads(block_size, rows_per_block, 1);

    switch (block_size)
    {
    case 128:
        sparse_mvm<128><<<blocks,threads>>>(mymat->d_rows, mymat->d_cols, mymat->d_values, 
                                            X->d_val, Y->d_val, mymat->nrows, mymat->ncols);
        break;
    case 64:
        sparse_mvm<64><<<blocks,threads>>>(mymat->d_rows, mymat->d_cols, mymat->d_values, 
                                            X->d_val, Y->d_val, mymat->nrows, mymat->ncols);
        break;
    case 32:
        sparse_mvm<32><<<blocks,threads>>>(mymat->d_rows, mymat->d_cols, mymat->d_values, 
                                            X->d_val, Y->d_val, mymat->nrows, mymat->ncols);
        break;
    case 16:
        sparse_mvm<16><<<blocks,threads>>>(mymat->d_rows, mymat->d_cols, mymat->d_values, 
                                            X->d_val, Y->d_val, mymat->nrows, mymat->ncols);
        break;
    case 8:
        sparse_mvm<8><<<blocks,threads>>>(mymat->d_rows, mymat->d_cols, mymat->d_values, 
                                            X->d_val, Y->d_val, mymat->nrows, mymat->ncols);
        break;
    case 4:
        sparse_mvm<4><<<blocks,threads>>>(mymat->d_rows, mymat->d_cols, mymat->d_values, 
                                            X->d_val, Y->d_val, mymat->nrows, mymat->ncols);
        break;
    case 2:
        sparse_mvm<2><<<blocks,threads>>>(mymat->d_rows, mymat->d_cols, mymat->d_values, 
                                            X->d_val, Y->d_val, mymat->nrows, mymat->ncols);
        break;
    default:
        sparse_mvm<1><<<blocks,threads>>>(mymat->d_rows, mymat->d_cols, mymat->d_values, 
                                            X->d_val, Y->d_val, mymat->nrows, mymat->ncols);
        break;
    }
}

int main(int argc, char const *argv[]) {

    if( argc < 2 ){
        cout << "Usage: ./vector_csr <matrix market file>" << endl;
        return -1;
    }

    int ierr {};

    string filename {string(argv[1])};

    // int ntrials {atoi(argv[2])};

    CSRMatrix *mymat {}; 

    CSRMatrixReader reader(filename);

    ierr = reader.mm_init_csr(&mymat); // allocate memory

    if(ierr){
        cout << "Error" << ierr << endl;
        return ierr;
    }

    int mnnzpr = reader.mm_read_csr(mymat); //read from file and convert from coo to csr

    cout << "mnnzpr: " << mnnzpr << endl;

    // mymat->print(); // Print all values. Commented out for large matrices.

    DenseVector X(mymat->ncols);

    X.generate(); // Fill with random numbers 

    DenseVector Y(mymat->ncols); // Initialize with zeros

    // X.print();
    // Y.print();

    // Using functional programming for mat mult to avoid operator overloading
    // No Need for warmup since threads have been used before to intialize vars
    run_test(mymat,&X,&Y,mnnzpr); 

    Y.update_host();
    
    // Y.print();

    DenseVector Ycsp(mymat->ncols); // Initialize with zeros

    // Use cuSparse
    // CUSPARSE APIs
    {
        cusparseHandle_t     handle = NULL;
        cusparseSpMatDescr_t matA;
        cusparseDnVecDescr_t vecX, vecY;
        void*                dBuffer    = NULL;
        size_t               bufferSize = 0;
        double alpha = 1.0;
        double beta  = 0.0;
        CHECK_CUSPARSE( cusparseCreate(&handle) )
        // Create sparse matrix A in CSR format
        CHECK_CUSPARSE( cusparseCreateCsr(&matA, mymat->nrows, mymat->ncols, mymat->nnz,
                                          mymat->d_rows, mymat->d_cols, mymat->d_values,
                                          CUSPARSE_INDEX_32I, CUSPARSE_INDEX_32I,
                                          CUSPARSE_INDEX_BASE_ZERO, CUDA_R_64F) )
        // Create dense vector X
        CHECK_CUSPARSE( cusparseCreateDnVec(&vecX, mymat->ncols, X.d_val, CUDA_R_64F) )
        // Create dense vector y
        CHECK_CUSPARSE( cusparseCreateDnVec(&vecY, mymat->nrows, Ycsp.d_val, CUDA_R_64F) )
        // allocate an external buffer if needed
        CHECK_CUSPARSE( cusparseSpMV_bufferSize(
                                     handle, CUSPARSE_OPERATION_NON_TRANSPOSE,
                                     &alpha, matA, vecX, &beta, vecY, CUDA_R_64F,
                                     CUSPARSE_SPMV_ALG_DEFAULT, &bufferSize) )
        checkCudaErrors( cudaMalloc(&dBuffer, bufferSize) );

        // execute SpMV
        CHECK_CUSPARSE( cusparseSpMV(handle, CUSPARSE_OPERATION_NON_TRANSPOSE,
                                     &alpha, matA, vecX, &beta, vecY, CUDA_R_64F,
                                     CUSPARSE_SPMV_ALG_DEFAULT, dBuffer) )

        // destroy matrix/vector descriptors
        CHECK_CUSPARSE( cusparseDestroySpMat(matA) )
        CHECK_CUSPARSE( cusparseDestroyDnVec(vecX) )
        CHECK_CUSPARSE( cusparseDestroyDnVec(vecY) )
        CHECK_CUSPARSE( cusparseDestroy(handle) )
    }

    Ycsp.update_host();
    // Ycsp.print();
        
    bool issame {true};    

    for( int i {}; i < Y.size; i++ ){
        issame *= ( fabs(Y.h_val[i] - Ycsp.h_val[i]) < EPS );
    }

    if(issame){
        cout << "Results are correct!" << endl;
    } else {
        cout << "Results are Wrong!" << endl;

        for(int i = 0; i < Y.size ; i++){
            if( fabs(Y.h_val[i] - Ycsp.h_val[i]) >= EPS )
                cout << i << ", Y: " << Y.h_val[i] << ",  Ycsp: " << Ycsp.h_val[i] << endl;
        }
    }

    delete mymat; // Calls destroyer

    mymat = nullptr; 

    return ierr;
}