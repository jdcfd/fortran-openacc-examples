
class DenseVector {
    public:
        int size;
        double * h_v;
        double * d_v;
        DenseVector(int n);
        ~DenseVector();
        void generate();
        void update_host();
        void update_device();
};