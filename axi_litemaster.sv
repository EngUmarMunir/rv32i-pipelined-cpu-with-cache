`timescale 1ns/1ps

module axi4_burst_ram #(
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 32,
    parameter DEPTH      = 4096
)(
    input  logic clk,
    input  logic reset,

    // =========================
    // WRITE ADDRESS CHANNEL
    // =========================
    input  logic [ADDR_WIDTH-1:0] S_AXI_AWADDR,
    input  logic [7:0]            S_AXI_AWLEN,
    input  logic [2:0]            S_AXI_AWSIZE,
    input  logic [1:0]            S_AXI_AWBURST,
    input  logic                  S_AXI_AWVALID,
    output logic                  S_AXI_AWREADY,

    // =========================
    // WRITE DATA CHANNEL
    // =========================
    input  logic [DATA_WIDTH-1:0] S_AXI_WDATA,
    input  logic [DATA_WIDTH/8-1:0] S_AXI_WSTRB,
    input  logic                  S_AXI_WLAST,
    input  logic                  S_AXI_WVALID,
    output logic                  S_AXI_WREADY,

    // =========================
    // WRITE RESPONSE
    // =========================
    output logic [1:0]            S_AXI_BRESP,
    output logic                  S_AXI_BVALID,
    input  logic                  S_AXI_BREADY,

    // =========================
    // READ ADDRESS CHANNEL
    // =========================
    input  logic [ADDR_WIDTH-1:0] S_AXI_ARADDR,
    input  logic [7:0]            S_AXI_ARLEN,
    input  logic [2:0]            S_AXI_ARSIZE,
    input  logic [1:0]            S_AXI_ARBURST,
    input  logic                  S_AXI_ARVALID,
    output logic                  S_AXI_ARREADY,

    // =========================
    // READ DATA CHANNEL
    // =========================
    output logic [DATA_WIDTH-1:0] S_AXI_RDATA,
    output logic                  S_AXI_RLAST,
    output logic [1:0]            S_AXI_RRESP,
    output logic                  S_AXI_RVALID,
    input  logic                  S_AXI_RREADY
);

    // =========================================================
    // MEMORY
    // =========================================================
    logic [31:0] RAM [0:DEPTH-1];

    assign S_AXI_BRESP = 2'b00;
    assign S_AXI_RRESP = 2'b00;

    // =========================================================
    // INTERNAL REGISTERS
    // =========================================================
    logic [ADDR_WIDTH-1:0] awaddr_q, araddr_q;
    logic [7:0] awlen_q, arlen_q;

    logic [7:0] w_cnt;
    logic [7:0] r_cnt;

    logic aw_active, ar_active;

    // =========================================================
    // WRITE CHANNEL
    // =========================================================
    assign S_AXI_AWREADY = !aw_active;
    assign S_AXI_WREADY  = aw_active;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            aw_active  <= 0;
            S_AXI_BVALID <= 0;
            w_cnt      <= 0;
        end else begin

            // Accept address
            if (S_AXI_AWVALID && S_AXI_AWREADY) begin
                awaddr_q  <= S_AXI_AWADDR;
                awlen_q   <= S_AXI_AWLEN;
                aw_active <= 1;
                w_cnt     <= 0;
            end

            // Accept write data
            if (aw_active && S_AXI_WVALID && S_AXI_WREADY) begin
                logic [ADDR_WIDTH-1:0] addr;
                addr = (awaddr_q[31:2] + w_cnt);

                RAM[addr] <= S_AXI_WDATA;

                if (w_cnt == awlen_q || S_AXI_WLAST) begin
                    aw_active   <= 0;
                    S_AXI_BVALID <= 1;
                end else begin
                    w_cnt <= w_cnt + 1;
                end
            end

            // Write response handshake
            if (S_AXI_BVALID && S_AXI_BREADY) begin
                S_AXI_BVALID <= 0;
            end
        end
    end

    // =========================================================
    // READ CHANNEL (PROPER BURST FSM)
    // =========================================================
    assign S_AXI_ARREADY = !ar_active;
    assign S_AXI_RVALID   = ar_active;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            ar_active <= 0;
            S_AXI_RLAST <= 0;
            r_cnt <= 0;
        end else begin

            // Accept read address
            if (S_AXI_ARVALID && S_AXI_ARREADY) begin
                araddr_q  <= S_AXI_ARADDR;
                arlen_q   <= S_AXI_ARLEN;
                ar_active <= 1;
                r_cnt     <= 0;
            end

            // Read burst transfer
            if (ar_active && S_AXI_RREADY) begin

                S_AXI_RDATA <= RAM[(araddr_q[31:2] + r_cnt)];

                if (r_cnt == arlen_q) begin
                    S_AXI_RLAST  <= 1;
                    ar_active    <= 0;
                end else begin
                    S_AXI_RLAST <= 0;
                    r_cnt <= r_cnt + 1;
                end
            end else begin
                S_AXI_RLAST <= 0;
            end
        end
    end

    // =========================================================
    // INIT MEMORY
    // =========================================================
    initial begin
        $readmemh("inst.mem", RAM);
    end

endmodule