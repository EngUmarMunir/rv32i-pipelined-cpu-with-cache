module cache_axi4_master (
    input  logic        clk,
    input  logic        reset,

    //------------------------------------------------------------
    // I-cache memory port (burst-capable, read-only)
    //------------------------------------------------------------
    input  logic        i_mem_req,
    input  logic [31:0] i_mem_addr,
    input  logic [3:0]  i_mem_burst_len,
    output logic [31:0] i_mem_rdata,
    output logic        i_mem_rvalid,
    output logic        i_mem_rlast,
    output logic        i_mem_ready,

    //------------------------------------------------------------
    // D-cache memory port (burst-capable read + single-beat write)
    //------------------------------------------------------------
    input  logic        d_mem_req,
    input  logic        d_mem_we,
    input  logic [3:0]  d_mem_be,
    input  logic [31:0] d_mem_addr,
    input  logic [31:0] d_mem_wdata,
    input  logic [3:0]  d_mem_burst_len,
    output logic [31:0] d_mem_rdata,
    output logic        d_mem_rvalid,
    output logic        d_mem_rlast,
    output logic        d_mem_ready,

    //------------------------------------------------------------
    // AXI4 master
    //------------------------------------------------------------
    output logic [31:0] M_AXI_AWADDR,
    output logic [7:0]  M_AXI_AWLEN,
    output logic [2:0]  M_AXI_AWSIZE,
    output logic [1:0]  M_AXI_AWBURST,
    output logic        M_AXI_AWVALID,
    input  logic        M_AXI_AWREADY,
    output logic [31:0] M_AXI_WDATA,
    output logic [3:0]  M_AXI_WSTRB,
    output logic        M_AXI_WLAST,
    output logic        M_AXI_WVALID,
    input  logic        M_AXI_WREADY,
    input  logic [1:0]  M_AXI_BRESP,
    input  logic        M_AXI_BVALID,
    output logic        M_AXI_BREADY,
    output logic [31:0] M_AXI_ARADDR,
    output logic [7:0]  M_AXI_ARLEN,
    output logic [2:0]  M_AXI_ARSIZE,
    output logic [1:0]  M_AXI_ARBURST,
    output logic        M_AXI_ARVALID,
    input  logic        M_AXI_ARREADY,
    input  logic [31:0] M_AXI_RDATA,
    input  logic [1:0]  M_AXI_RRESP,
    input  logic        M_AXI_RVALID,
    input  logic        M_AXI_RLAST,
    output logic        M_AXI_RREADY
);

    //----------------------------------------------------
    // STATE
    //----------------------------------------------------
    typedef enum logic [2:0] {
        IDLE,
        READ_ADDR,
        READ_DATA,
        WRITE_ADDR,
        WRITE_RESP
    } state_t;

    state_t state;

    logic [31:0] active_addr;
    logic [31:0] active_wdata;
    logic [3:0]  active_be;
    logic [7:0]  active_arlen;   // AXI ARLEN = beats-1
    logic        is_iop;         // current transaction is for the icache
    logic        aw_done;        // AW handshake completed
    logic        w_done;         // W handshake completed

    //----------------------------------------------------
    // ARBITRATION (combinational, dcache priority)
    //----------------------------------------------------
    logic grant_d, grant_i;
    assign grant_d = d_mem_req;
    assign grant_i = i_mem_req && !d_mem_req;

    //----------------------------------------------------
    // COMBINATIONAL AXI DRIVING
    //----------------------------------------------------
    always_comb begin
        M_AXI_ARVALID = 0;
        M_AXI_RREADY  = 0;
        M_AXI_AWVALID = 0;
        M_AXI_WVALID  = 0;
        M_AXI_BREADY  = 0;

        M_AXI_ARADDR  = active_addr;
        M_AXI_ARLEN   = active_arlen;
        M_AXI_ARSIZE  = 3'b010;   // 4 bytes/beat
        M_AXI_ARBURST = 2'b01;    // INCR

        M_AXI_AWADDR  = active_addr;
        M_AXI_AWLEN   = 8'd0;     // single-beat writes only
        M_AXI_AWSIZE  = 3'b010;
        M_AXI_AWBURST = 2'b01;

        M_AXI_WDATA   = active_wdata;
        M_AXI_WSTRB   = active_be;
        M_AXI_WLAST   = 1'b1;

        case (state)
            READ_ADDR:  M_AXI_ARVALID = 1;
            READ_DATA:  M_AXI_RREADY  = 1;
            WRITE_ADDR: begin
                M_AXI_AWVALID = !aw_done;
                M_AXI_WVALID  = !w_done;
            end
            WRITE_RESP: M_AXI_BREADY = 1;
            default: ;
        endcase
    end

    //----------------------------------------------------
    // CACHE-FACING OUTPUTS (combinational)
    //----------------------------------------------------
    always_comb begin
        // Request-accept handshakes: pulse 'ready' the cycle the
        // address phase is accepted by the slave.
        i_mem_ready = (state == READ_ADDR) && M_AXI_ARREADY && is_iop;
        d_mem_ready = ((state == READ_ADDR) && M_AXI_ARREADY && !is_iop) ||
                      ((state == WRITE_ADDR) &&
                       (aw_done || M_AXI_AWREADY) &&
                       (w_done  || M_AXI_WREADY));

        // Read data beats: forward directly from the AXI R channel.
        i_mem_rvalid = (state == READ_DATA) && M_AXI_RVALID && is_iop;
        i_mem_rdata  = M_AXI_RDATA;
        i_mem_rlast  = M_AXI_RLAST;

        d_mem_rvalid = (state == READ_DATA) && M_AXI_RVALID && !is_iop;
        d_mem_rdata  = M_AXI_RDATA;
        d_mem_rlast  = M_AXI_RLAST;
    end

    //----------------------------------------------------
    // SEQUENTIAL
    //----------------------------------------------------
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            state        <= IDLE;
            is_iop       <= 0;
            active_addr  <= 0;
            active_wdata <= 0;
            active_be    <= 0;
            active_arlen <= 0;
            aw_done      <= 0;
            w_done       <= 0;
        end else begin
            case (state)
                //--------------------------------------------
                IDLE: begin
                    aw_done <= 0;
                    w_done  <= 0;
                    if (grant_d) begin
                        active_addr  <= d_mem_addr;
                        active_wdata <= d_mem_wdata;
                        active_be    <= d_mem_be;
                        active_arlen <= d_mem_burst_len - 8'd1; // ARLEN = beats-1
                        is_iop       <= 0;
                        state        <= d_mem_we ? WRITE_ADDR : READ_ADDR;
                    end
                    else if (grant_i) begin
                        active_addr  <= i_mem_addr;
                        active_arlen <= i_mem_burst_len - 8'd1;
                        is_iop       <= 1;
                        state        <= READ_ADDR;
                    end
                end

                //--------------------------------------------
                READ_ADDR: begin
                    if (M_AXI_ARREADY)
                        state <= READ_DATA;
                end

                //--------------------------------------------
                // Streams beats out combinationally via *_mem_rvalid/
                // *_mem_rdata/*_mem_rlast above. Return to IDLE once
                // the last beat (RLAST) has been accepted.
                READ_DATA: begin
                    if (M_AXI_RVALID && M_AXI_RLAST)
                        state <= IDLE;
                end

                //--------------------------------------------
                // AW and W channels may be accepted on different
                // cycles; latch each independently and move to
                // WRITE_RESP once both have completed.
                WRITE_ADDR: begin
                    if (!aw_done && M_AXI_AWREADY)
                        aw_done <= 1;
                    if (!w_done && M_AXI_WREADY)
                        w_done <= 1;

                    if ((aw_done || M_AXI_AWREADY) && (w_done || M_AXI_WREADY))
                        state <= WRITE_RESP;
                end

                //--------------------------------------------
                WRITE_RESP: begin
                    if (M_AXI_BVALID)
                        state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule

  