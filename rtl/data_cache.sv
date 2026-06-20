`timescale 1ns / 1ps
module dcache_nonblocking (
    input logic clk,
    input logic rst,
    input logic mem_read,
    input logic mem_write,
    input logic [2:0] funct3,
    input logic [31:0] cpu_addr,
    input logic [31:0] cpu_wdata,
    output logic [31:0] cpu_rdata,
    output logic hit,
    output logic busy,
    output logic valid_data,
    // Memory interface
    output logic mem_req,
    output logic mem_we,
    output logic [3:0] mem_be,
    output logic [31:0] mem_addr,
    output logic [31:0] mem_wdata,
    output logic [3:0] mem_burst_len,
    input logic [31:0] mem_rdata,
    input logic mem_rvalid,
    input logic mem_rlast,
    input logic mem_ready
);

    localparam CACHE_LINES = 16;
    localparam INDEX_BITS = 4;
    localparam TAG_BITS = 24;
    localparam LINE_WORDS = 4;
    localparam OFF_BITS = 2;

    logic [31:0] data_array [0:CACHE_LINES-1][0:LINE_WORDS-1];
    logic [TAG_BITS-1:0] tag_array [0:CACHE_LINES-1];
    logic valid_array [0:CACHE_LINES-1];

    logic [INDEX_BITS-1:0] index;
    logic [TAG_BITS-1:0] tag;
    logic [OFF_BITS-1:0] word_off;
    logic [1:0] byte_off;
    assign index = cpu_addr[7:4];
    assign tag = cpu_addr[31:8];
    assign word_off = cpu_addr[3:2];
    assign byte_off = cpu_addr[1:0];

    logic tag_hit;
    assign tag_hit = valid_array[index] && (tag_array[index] == tag);
    assign hit = tag_hit && !busy;

    // Pending state
    logic [INDEX_BITS-1:0] miss_idx;
    logic [TAG_BITS-1:0] miss_tag;
    logic pending_write;
    logic [31:0] pending_wdata;
    logic [2:0] pending_funct3;
    logic [OFF_BITS-1:0] pending_word_off;
    logic [1:0] pending_byte_off;

    logic [TAG_BITS-1:0] wt_tag;
    logic [INDEX_BITS-1:0] wt_idx;
    logic [OFF_BITS-1:0] beat_cnt;
    logic write_done_q;

    typedef enum logic [2:0] {
        IDLE, READ_REQ, READ_REFILL, WRITE_HIT_WAIT, WRITE_ALLOC_WAIT
    } state_t;
    state_t state;

    logic refill_in_progress;
    logic addr_conflicts_refill;
    assign refill_in_progress = (state == READ_REQ) || (state == READ_REFILL);
    assign addr_conflicts_refill = refill_in_progress && (index == miss_idx) && (tag == miss_tag);

    // Helper functions (same as before)
    function automatic logic [31:0] load_extend(input logic [31:0] word, input logic [1:0] off, input logic [2:0] f3);
        // ... (keep your original load_extend function)
        logic [7:0] b;
        logic [15:0] h;
        case (off)
            2'b00: b = word[7:0]; 2'b01: b = word[15:8];
            2'b10: b = word[23:16]; 2'b11: b = word[31:24];
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

    function automatic logic [3:0] gen_be(input logic [1:0] off, input logic [2:0] f3);
        case (f3)
            3'b000: gen_be = 4'b0001 << off;
            3'b001: gen_be = off[1] ? 4'b1100 : 4'b0011;
            3'b010: gen_be = 4'b1111;
            default: gen_be = 4'b0000;
        endcase
    endfunction

    function automatic logic [31:0] align_store(input logic [31:0] data, input logic [1:0] off, input logic [2:0] f3);
        case (f3)
            3'b000: align_store = {24'b0, data[7:0]} << (off * 8);
            3'b001: align_store = {16'b0, data[15:0]} << (off[1] * 16);
            3'b010: align_store = data;
            default: align_store = data;
        endcase
    endfunction

    function automatic logic [31:0] update_word(input logic [31:0] old_w, input logic [31:0] new_w, input logic [3:0] be);
        update_word = old_w;
        if (be[0]) update_word[7:0] = new_w[7:0];
        if (be[1]) update_word[15:8] = new_w[15:8];
        if (be[2]) update_word[23:16] = new_w[23:16];
        if (be[3]) update_word[31:24] = new_w[31:24];
    endfunction

    // Combinational outputs
    always_comb begin
        cpu_rdata = 32'b0;
        busy = 1'b0;
        valid_data = 1'b0;
        mem_req = 1'b0;
        mem_we = 1'b0;
        mem_be = 4'b0;
        mem_addr = 32'b0;
        mem_wdata = 32'b0;
        mem_burst_len = LINE_WORDS[3:0];

        if (mem_read) begin
            if (tag_hit && !addr_conflicts_refill) begin
                cpu_rdata = load_extend(data_array[index][word_off], byte_off, funct3);
                valid_data = 1'b1;
            end else begin
                busy = 1'b1;
            end
        end else if (mem_write) begin
            if (tag_hit && !addr_conflicts_refill && (state == IDLE || state == WRITE_HIT_WAIT)) begin
                busy = 1'b0;
                valid_data = 1'b1;
            end else if (write_done_q) begin
                busy = 1'b0;
                valid_data = 1'b1;
            end else begin
                busy = 1'b1;
            end
        end

        // Memory bus
        case (state)
            READ_REQ: begin
                mem_req = 1'b1;
                mem_we = 1'b0;
                mem_addr = {miss_tag, miss_idx, {(OFF_BITS+2){1'b0}}};
            end
            WRITE_HIT_WAIT, WRITE_ALLOC_WAIT: begin
                mem_req = 1'b1;
                mem_we = 1'b1;
                mem_burst_len = 4'd1;
                mem_addr = {wt_tag, wt_idx, pending_word_off, 2'b00};
                mem_be = gen_be(pending_byte_off, pending_funct3);
                mem_wdata = align_store(pending_wdata, pending_byte_off, pending_funct3);
            end
            default: ;
        endcase
    end

    // Sequential logic
    integer i, j;
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= IDLE;
            pending_write <= 1'b0;
            write_done_q <= 1'b0;
            beat_cnt <= '0;
            for (i = 0; i < CACHE_LINES; i++) begin
                valid_array[i] <= 1'b0;
                tag_array[i] <= '0;
                for (j = 0; j < LINE_WORDS; j++)
                    data_array[i][j] <= '0;
            end
        end else begin
            write_done_q <= 1'b0;

            case (state)
                IDLE: begin
                    if (mem_read && !tag_hit) begin
                        miss_idx <= index; miss_tag <= tag;
                        state <= READ_REQ;
                    end else if (mem_write) begin
                        if (tag_hit) begin
                            data_array[index][word_off] <= update_word(
                                data_array[index][word_off],
                                align_store(cpu_wdata, byte_off, funct3),
                                gen_be(byte_off, funct3)
                            );
                            wt_tag <= tag; wt_idx <= index;
                            pending_wdata <= cpu_wdata;
                            pending_funct3 <= funct3;
                            pending_word_off <= word_off;
                            pending_byte_off <= byte_off;
                            state <= WRITE_HIT_WAIT;
                        end else begin
                            // write miss allocate
                            miss_idx <= index; miss_tag <= tag;
                            wt_tag <= tag; wt_idx <= index;
                            pending_write <= 1'b1;
                            pending_wdata <= cpu_wdata;
                            pending_funct3 <= funct3;
                            pending_word_off <= word_off;
                            pending_byte_off <= byte_off;
                            state <= READ_REQ;
                        end
                    end
                end

                READ_REQ: if (mem_ready) state <= READ_REFILL;

                READ_REFILL: begin
                    if (mem_rvalid) begin
                        if (pending_write && (beat_cnt == pending_word_off)) begin
                            data_array[miss_idx][beat_cnt] <= update_word(mem_rdata,
                                align_store(pending_wdata, pending_byte_off, pending_funct3),
                                gen_be(pending_byte_off, pending_funct3));
                        end else begin
                            data_array[miss_idx][beat_cnt] <= mem_rdata;
                        end

                        if (mem_rlast) begin
                            valid_array[miss_idx] <= 1'b1;
                            tag_array[miss_idx] <= miss_tag;
                            state <= pending_write ? WRITE_ALLOC_WAIT : IDLE;
                        end else begin
                            beat_cnt <= beat_cnt + 1;
                        end
                    end
                end

                WRITE_HIT_WAIT, WRITE_ALLOC_WAIT: begin
                    if (mem_ready) begin
                        write_done_q <= 1'b1;
                        state <= IDLE;
                    end
                end
            endcase
        end
    end
endmodule
