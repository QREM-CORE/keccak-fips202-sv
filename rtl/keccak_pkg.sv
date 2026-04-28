package keccak_pkg;
    import qrem_global_pkg::*;

    // Misc. Bit Sizes
    parameter int BYTE_SIZE = 8;

    // State Array Dimension Bit Sizes
    parameter int LANE_SIZE = 64;
    parameter int ROW_SIZE  = 5;
    parameter int COL_SIZE  = 5;

    // Iota Step
    parameter int ROUND_INDEX_SIZE = 5;
    parameter int MAX_ROUNDS = 24;
    parameter int L_SIZE = 7;

    // Keccak Structure
    parameter int DWIDTH = qrem_global_pkg::DWIDTH; // Input data is 8 bytes
    parameter int DATA_BYTE_NUM = DWIDTH/8;
    parameter int KEEP_WIDTH = DWIDTH/8; // 1 bit for every data byte
    parameter int X_WIDTH = $clog2(ROW_SIZE);
    parameter int Y_WIDTH = $clog2(COL_SIZE);

    // Different Keccak Modes
    typedef enum {
        SHA3_256,
        SHA3_512,
        SHAKE128,
        SHAKE256
    } keccak_mode;
    parameter int MODE_NUM = 4;
    parameter int MODE_SEL_WIDTH = $clog2(MODE_NUM);

    // Setup Parameters
    parameter int CAPACITY_WIDTH = 11;
    parameter int RATE_WIDTH = 11;
    parameter int SUFFIX_WIDTH = BYTE_SIZE;
    parameter int SUFFIX_LEN_WIDTH = 3;

    parameter int BYTE_ABSORB_WIDTH = 8;
    parameter int XOF_LEN_WIDTH = 16;

    // Round Constants (FIPS 202 Table 5)
    parameter logic [LANE_SIZE-1:0] KECCAK_ROUND_CONSTANTS [24] = '{
        64'h0000000000000001, 64'h0000000000008082, 64'h800000000000808a, 64'h8000000080008000,
        64'h000000000000808b, 64'h0000000080000001, 64'h8000000080008081, 64'h8000000000008009,
        64'h000000000000008a, 64'h0000000000000088, 64'h0000000080008009, 64'h000000008000000a,
        64'h000000008000808b, 64'h800000000000008b, 64'h8000000000008089, 64'h8000000000008003,
        64'h8000000000008002, 64'h8000000000000080, 64'h000000000000800a, 64'h800000008000000a,
        64'h8000000080008081, 64'h8000000000008080, 64'h0000000080000001, 64'h8000000080008008
    };

endpackage : keccak_pkg
