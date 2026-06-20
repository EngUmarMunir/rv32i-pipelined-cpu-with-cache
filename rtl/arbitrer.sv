`timescale 1ns / 1ps
module cache_axi4_master (
    input logic clk,
    input logic reset,
    // I-cache
    input logic i_mem_req,
    input logic [31:0] i_mem_addr,
    input logic [3:0] i_mem_burst_len,
    output logic [31:0] i_mem_rdata,
    output logic i_mem_rvalid,
    output logic i_mem_rlast,
    output logic i_mem_ready,
    // D-cache
    input logic d_mem_req,
    input logic d_mem_we,
    input logic [3:0] d_mem_be,
    input logic [31:0] d_mem_addr,
    input logic [31:0] d_mem_wdata,
    input logic [3:0] d_mem_burst_len,
    output logic [31:0] d_mem_rdata,
    output logic d_mem_rvalid,
    output logic d_mem_rlast,
    output logic d_mem_ready,
    // AXI4
    output logic [31:0] M_AXI_AWADDR,
    output logic [7:0] M_AXI_AWLEN,
    output logic [2:0] M_AXI_AWSIZE,
    output logic [1:0] M_AXI_AWBURST,
    output logic M_AXI_AWVALID,
    input logic M_AXI_AWREADY,
    output logic [31:0] M_AXI_WDATA,
    output logic [3:0] M_AXI_WSTRB,
    output logic M_AXI_WLAST,
    output logic M_AXI_WVALID,
    input logic M_AXI_WREADY,
    input logic [1:0] M_AXI_BRESP,
    input logic M_AXI_BVALID,
    output logic M_AXI_BREADY,
    output logic [31:0] M_AXI_ARADDR,
    output logic [7:0] M_AXI_ARLEN,
    output logic [2:0] M_AXI_ARSIZE,
    output logic [1:0] M_AXI_ARBURST,
    output logic M_AXI_ARVALID,
    input logic M_AXI_ARREADY,
    input logic [31:0] M_AXI_RDATA,
    input logic [1:0] M_AXI_RRESP,
    input logic M_AXI_RVALID,
    input logic M_AXI_RLAST,
    output logic M_AXI_RREADY
);

    typedef enum logic [2:0] {
        IDLE, READ_ADDR, READ_DATA, WRITE_ADDR, WRITE_RESP
    } state_t;
    state_t state;

    logic [31:0] active_addr, active_wdata;
    logic [3:0]  active_be;
    logic [7:0]  active_arlen;
    logic is_iop;
    logic aw_done, w_done;

    logic [1:0] suppress_i_sr, suppress_d_sr;
    wire suppress_i = |suppress_i_sr;
    wire suppress_d = |suppress_d_sr;

    always_comb begin
        M_AXI_ARVALID = 1'b0; M_AXI_RREADY = 1'b0;
        M_AXI_AWVALID = 1'b0; M_AXI_WVALID = 1'b0; M_AXI_BREADY = 1'b0;

        M_AXI_ARADDR = active_addr; M_AXI_ARLEN = active_arlen;
        M_AXI_ARSIZE = 3'b010; M_AXI_ARBURST = 2'b01;

        M_AXI_AWADDR = active_addr; M_AXI_AWLEN = 8'd0;
        M_AXI_AWSIZE = 3'b010; M_AXI_AWBURST = 2'b01;
        M_AXI_WDATA = active_wdata;
        M_AXI_WSTRB = active_be;
        M_AXI_WLAST = 1'b1;

        case (state)
            READ_ADDR: M_AXI_ARVALID = 1'b1;
            READ_DATA: M_AXI_RREADY = 1'b1;
            WRITE_ADDR: begin
                M_AXI_AWVALID = !aw_done;
                M_AXI_WVALID  = !w_done;
            end
            WRITE_RESP: M_AXI_BREADY = 1'b1;
            default:;
        endcase
    end

    assign i_mem_ready = (state == READ_ADDR) && M_AXI_ARREADY && is_iop;
    assign d_mem_ready = (state == WRITE_ADDR && (aw_done || M_AXI_AWREADY) && (w_done || M_AXI_WREADY)) ||
                         (!is_iop && state == READ_ADDR && M_AXI_ARREADY);

    assign i_mem_rvalid = (state == READ_DATA) && M_AXI_RVALID && is_iop;
    assign d_mem_rvalid = (state == READ_DATA) && M_AXI_RVALID && !is_iop;
    assign i_mem_rdata = M_AXI_RDATA;
    assign d_mem_rdata = M_AXI_RDATA;
    assign i_mem_rlast = M_AXI_RLAST;
    assign d_mem_rlast = M_AXI_RLAST;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            state <= IDLE;
            is_iop <= 1'b0;
            active_addr <= 0; active_wdata <= 0; active_be <= 0; active_arlen <= 0;
            aw_done <= 0; w_done <= 0;
            suppress_i_sr <= 0; suppress_d_sr <= 0;
        end else begin
            suppress_i_sr <= suppress_i_sr >> 1;
            suppress_d_sr <= suppress_d_sr >> 1;

            case (state)
                IDLE: begin
                    aw_done <= 0; w_done <= 0;
                    if (d_mem_req && d_mem_we && !suppress_d) begin
                        active_addr <= d_mem_addr; active_wdata <= d_mem_wdata;
                        active_be <= d_mem_be; is_iop <= 0;
                        state <= WRITE_ADDR;
                    end else if (d_mem_req && !d_mem_we && !suppress_d) begin
                        active_addr <= d_mem_addr; active_arlen <= d_mem_burst_len - 1;
                        is_iop <= 0; state <= READ_ADDR;
                    end else if (i_mem_req && !suppress_i) begin
                        active_addr <= i_mem_addr; active_arlen <= i_mem_burst_len - 1;
                        is_iop <= 1; state <= READ_ADDR;
                    end
                end

                READ_ADDR: if (M_AXI_ARREADY) begin
                    if (is_iop) suppress_i_sr <= 2'b11;
                    else suppress_d_sr <= 2'b11;
                    state <= READ_DATA;
                end

                READ_DATA: if (M_AXI_RVALID && M_AXI_RLAST) state <= IDLE;

                WRITE_ADDR: begin
                    if (!aw_done && M_AXI_AWREADY) aw_done <= 1;
                    if (!w_done && M_AXI_WREADY) w_done <= 1;
                    if ((aw_done || M_AXI_AWREADY) && (w_done || M_AXI_WREADY)) begin
                        suppress_d_sr <= 2'b11;
                        state <= WRITE_RESP;
                    end
                end

                WRITE_RESP: if (M_AXI_BVALID) state <= IDLE;
            endcase
        end
    end
endmodule
