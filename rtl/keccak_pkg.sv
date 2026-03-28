package keccak_pkg;
    // Misc. Bit Sizes
    parameter int BYTE_SIZE = 8;

    // State Array Dimension Bit Sizes
    parameter int LANE_SIZE = 64;
    parameter int ROW_SIZE  = 5;
    parameter int COL_SIZE  = 5;

    // Step Map
    parameter int STEP_NUM = 5;
    parameter int STEP_SEL_WIDTH = $clog2(STEP_NUM);

    // Iota Step
    parameter int ROUND_INDEX_SIZE = 5;
    parameter int MAX_ROUNDS = 24;
    parameter int L_SIZE = 7;

    // Keccak Structure
    parameter int DWIDTH = 64; // Input data is 8 bytes
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

    // Different step selector options
    typedef enum {
        IDLE_STEP,
        ZERO_STEP,
        THETA_STEP,
        RHO_STEP,
        PI_STEP,
        CHI_STEP,
        IOTA_STEP
    } keccak_step_t;

endpackage : keccak_pkg
