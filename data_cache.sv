module dcache_nonblocking (
    input  logic        clk,
    input  logic        rst,
    input  logic        mem_read,
    input  logic        mem_write,
    input  logic [2:0]  funct3,
    input  logic [31:0] cpu_addr,
    input  logic [31:0] cpu_wdata,
    output logic [31:0] cpu_rdata,
    output logic        hit,
    output logic        busy,
    output logic        valid_data,

    // Memory interface
    output logic        mem_req,
    output logic        mem_we,
    output logic [3:0]  mem_be,
    output logic [31:0] mem_addr,
    output logic [31:0] mem_wdata,
    output logic [3:0]  mem_burst_len,
    input  logic [31:0] mem_rdata,
    input  logic        mem_rvalid,
    input  logic        mem_rlast,
    input  logic        mem_ready        // one-cycle pulse from cache_axi4_master
);
    //----------------------------------------------------
    // CONFIG
    //----------------------------------------------------
    localparam CACHE_LINES = 16;
    localparam INDEX_BITS  = 4;
    localparam TAG_BITS    = 24;
    localparam LINE_WORDS  = 4;
    localparam OFF_BITS    = 2;  // log2(LINE_WORDS)

    //----------------------------------------------------
    // STORAGE
    //----------------------------------------------------
    logic [31:0]         data_array  [0:CACHE_LINES-1][0:LINE_WORDS-1];
    logic [TAG_BITS-1:0] tag_array   [0:CACHE_LINES-1];
    logic                valid_array [0:CACHE_LINES-1];

    //----------------------------------------------------
    // ADDRESS DECOMPOSITION
    //   [31:8]  tag      (24 bits)
    //   [7:4]   index    (4 bits)
    //   [3:2]   word_off (2 bits)
    //   [1:0]   byte_off (2 bits)
    //----------------------------------------------------
    logic [INDEX_BITS-1:0] index;
    logic [TAG_BITS-1:0]   tag;
    logic [OFF_BITS-1:0]   word_off;
    logic [1:0]            byte_off;

    assign index    = cpu_addr[7:4];
    assign tag      = cpu_addr[31:8];
    assign word_off = cpu_addr[3:2];
    assign byte_off = cpu_addr[1:0];

    assign hit = valid_array[index] && (tag_array[index] == tag);

    //----------------------------------------------------
    // Captured miss / pending-store state
    //----------------------------------------------------
    logic [INDEX_BITS-1:0] miss_idx;
    logic [TAG_BITS-1:0]   miss_tag;

    logic                pending_write;
    logic [31:0]         pending_wdata;
    logic [2:0]          pending_funct3;
    logic [OFF_BITS-1:0] pending_word_off;
    logic [1:0]          pending_byte_off;

    // Full captured address for the write-through so the mem_addr
    // computation is unambiguous (tag + index + word_off).
    logic [TAG_BITS-1:0]   wt_tag;
    logic [INDEX_BITS-1:0] wt_idx;

    logic [OFF_BITS:0] beat_cnt;

    typedef enum logic [2:0] {
        IDLE,
        READ_REQ,         // burst-read command issued, wait mem_ready
        READ_REFILL,      // streaming in LINE_WORDS beats
        WRITE_HIT_WAIT,   // write-through for a write-hit, wait mem_ready
        WRITE_ALLOC_WAIT  // write-through after write-allocate refill, wait mem_ready
    } state_t;
    state_t state;

    //----------------------------------------------------
    // Hit-under-miss conflict check
    //----------------------------------------------------
    logic refill_in_progress;
    logic addr_conflicts_refill;

    assign refill_in_progress    = (state == READ_REQ) || (state == READ_REFILL);
    assign addr_conflicts_refill = refill_in_progress &&
                                   (index == miss_idx) && (tag == miss_tag);

    //----------------------------------------------------
    // Helper functions
    //----------------------------------------------------
    function automatic logic [31:0] load_extend(
        input logic [31:0] word,
        input logic [1:0]  off,
        input logic [2:0]  f3
    );
        logic [7:0]  b;
        logic [15:0] h;
        case (off)
            2'b00: b = word[7:0];
            2'b01: b = word[15:8];
            2'b10: b = word[23:16];
            2'b11: b = word[31:24];
        endcase
        h = off[1] ? word[31:16] : word[15:0];
        case (f3)
            3'b000: load_extend = {{24{b[7]}}, b};
            3'b001: load_extend = {{16{h[15]}}, h};
            3'b010: load_extend = word;
            3'b100: load_extend = {24'b0, b};
            3'b101: load_extend = {16'b0, h};
            default: load_extend = word;
        endcase
    endfunction

    function automatic logic [3:0] gen_be(
        input logic [1:0] off,
        input logic [2:0] f3
    );
        case (f3)
            3'b000: gen_be = 4'b0001 << off;
            3'b001: gen_be = off[1] ? 4'b1100 : 4'b0011;
            3'b010: gen_be = 4'b1111;
            default: gen_be = 4'b0000;
        endcase
    endfunction

    function automatic logic [31:0] align_store(
        input logic [31:0] data,
        input logic [1:0]  off,
        input logic [2:0]  f3
    );
        case (f3)
            3'b000: align_store = {24'b0, data[7:0]}  << (off * 8);
            3'b001: align_store = {16'b0, data[15:0]} << (off[1] * 16);
            3'b010: align_store = data;
            default: align_store = data;
        endcase
    endfunction

    function automatic logic [31:0] update_word(
        input logic [31:0] old_w,
        input logic [31:0] new_w,
        input logic [3:0]  be
    );
        update_word = old_w;
        if (be[0]) update_word[7:0]   = new_w[7:0];
        if (be[1]) update_word[15:8]  = new_w[15:8];
        if (be[2]) update_word[23:16] = new_w[23:16];
        if (be[3]) update_word[31:24] = new_w[31:24];
    endfunction

    //----------------------------------------------------
    // Combinational outputs
    //----------------------------------------------------
    always_comb begin
        cpu_rdata     = 32'b0;
        busy          = 0;
        valid_data    = 0;
        mem_req       = 0;
        mem_we        = 0;
        mem_be        = 4'b0;
        mem_addr      = 32'b0;
        mem_wdata     = 32'b0;
        mem_burst_len = LINE_WORDS[3:0];

        //--------------------------------------------------
        // CPU-facing result
        //--------------------------------------------------
        if (mem_read) begin
            if (hit && !addr_conflicts_refill) begin
                // Normal cache hit
                cpu_rdata  = load_extend(data_array[index][word_off], byte_off, funct3);
                valid_data = 1;
                busy       = 0;
            end
            else if (state == READ_REFILL && mem_rvalid &&
                     (beat_cnt[OFF_BITS-1:0] == word_off) &&
                     (index == miss_idx) && (tag == miss_tag) &&
                     !pending_write) begin
                // Early-forward: the word we need is arriving this cycle
                cpu_rdata  = load_extend(mem_rdata, byte_off, funct3);
                valid_data = 1;
                busy       = 0;
            end
            else begin
                busy = 1;
            end
        end
        else if (mem_write) begin
            // Write is busy until its write-through handshake completes.
            // mem_ready is a one-cycle pulse from cache_axi4_master.
            if ((state == WRITE_HIT_WAIT || state == WRITE_ALLOC_WAIT) && mem_ready) begin
                busy       = 0;
                valid_data = 1;
            end else begin
                busy = 1;
            end
        end

        if (!mem_read && !mem_write) begin
            busy       = 0;
            valid_data = 0;
        end

        //--------------------------------------------------
        // Memory bus driving
        //--------------------------------------------------
        case (state)
            READ_REQ: begin
                // Burst-read to refill the missed cache line.
                // Address is line-aligned (word_off and byte_off = 0).
                mem_req       = 1;
                mem_we        = 0;
                mem_addr      = {miss_tag, miss_idx, {(OFF_BITS+2){1'b0}}};
                mem_burst_len = LINE_WORDS[3:0];
            end

            WRITE_HIT_WAIT, WRITE_ALLOC_WAIT: begin
                // Single-beat write-through to memory.
                // Use wt_tag/wt_idx (captured at the time of the store
                // request) plus the pending word/byte offsets so the
                // address is always correct regardless of what the CPU
                // is currently presenting.
                mem_req   = 1;
                mem_we    = 1;
                mem_addr  = {wt_tag, wt_idx,
                             pending_word_off, 2'b00};
                mem_be    = gen_be(pending_byte_off, pending_funct3);
                mem_wdata = align_store(pending_wdata,
                                        pending_byte_off,
                                        pending_funct3);
            end

            default: ;
        endcase
    end

    //----------------------------------------------------
    // Sequential logic
    //----------------------------------------------------
    integer i, j;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state            <= IDLE;
            pending_write    <= 0;
            miss_idx         <= '0;
            miss_tag         <= '0;
            wt_tag           <= '0;
            wt_idx           <= '0;
            pending_wdata    <= '0;
            pending_funct3   <= '0;
            pending_word_off <= '0;
            pending_byte_off <= '0;
            beat_cnt         <= '0;
            for (i = 0; i < CACHE_LINES; i++) begin
                valid_array[i] <= 0;
                tag_array[i]   <= '0;
                for (j = 0; j < LINE_WORDS; j++)
                    data_array[i][j] <= 0;
            end
        end else begin
            case (state)
                //--------------------------------------------
                IDLE: begin
                    if (mem_read && !hit) begin
                        // Read miss: issue burst refill
                        miss_idx      <= index;
                        miss_tag      <= tag;
                        pending_write <= 0;
                        beat_cnt      <= '0;
                        state         <= READ_REQ;
                    end
                    else if (mem_write) begin
                        if (hit) begin
                            // Write hit: update cache line and write-through
                            data_array[index][word_off] <= update_word(
                                data_array[index][word_off],
                                align_store(cpu_wdata, byte_off, funct3),
                                gen_be(byte_off, funct3)
                            );
                            // Capture write-through address from live CPU signals
                            wt_tag           <= tag;
                            wt_idx           <= index;
                            pending_wdata    <= cpu_wdata;
                            pending_funct3   <= funct3;
                            pending_word_off <= word_off;
                            pending_byte_off <= byte_off;
                            state            <= WRITE_HIT_WAIT;
                        end else begin
                            // Write miss: write-allocate -> refill line, then store
                            miss_idx         <= index;
                            miss_tag         <= tag;
                            // Also capture as write-through target (same address)
                            wt_tag           <= tag;
                            wt_idx           <= index;
                            pending_write    <= 1;
                            pending_wdata    <= cpu_wdata;
                            pending_funct3   <= funct3;
                            pending_word_off <= word_off;
                            pending_byte_off <= byte_off;
                            beat_cnt         <= '0;
                            state            <= READ_REQ;
                        end
                    end
                end

                //--------------------------------------------
                READ_REQ: begin
                    // Hold mem_req until the arbiter issues mem_ready.
                    if (mem_ready) begin
                        beat_cnt <= '0;
                        state    <= READ_REFILL;
                    end
                end

                //--------------------------------------------
                READ_REFILL: begin
                    if (mem_rvalid) begin
                        if (pending_write &&
                            (beat_cnt[OFF_BITS-1:0] == pending_word_off)) begin
                            // Merge the pending store into the arriving beat
                            data_array[miss_idx][beat_cnt[OFF_BITS-1:0]] <=
                                update_word(
                                    mem_rdata,
                                    align_store(pending_wdata,
                                                pending_byte_off,
                                                pending_funct3),
                                    gen_be(pending_byte_off, pending_funct3)
                                );
                        end else begin
                            data_array[miss_idx][beat_cnt[OFF_BITS-1:0]] <= mem_rdata;
                        end

                        if (mem_rlast) begin
                            valid_array[miss_idx] <= 1;
                            tag_array[miss_idx]   <= miss_tag;
                            beat_cnt              <= '0;
                            state <= pending_write ? WRITE_ALLOC_WAIT : IDLE;
                        end else begin
                            beat_cnt <= beat_cnt + 1'b1;
                        end
                    end
                end

                //--------------------------------------------
                WRITE_HIT_WAIT,
                WRITE_ALLOC_WAIT: begin
                    // mem_ready is a one-cycle pulse from cache_axi4_master
                    // acknowledging that the write-through beat has been
                    // accepted (AW+W channels both handshaked).
                    if (mem_ready) begin
                        pending_write <= 0;
                        state         <= IDLE;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
