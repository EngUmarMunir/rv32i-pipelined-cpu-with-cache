`timescale 1ns / 1ps


module IF_ID (
    input  logic        clk, reset, flush, en,
    input  logic [31:0] InstrF, PCF, PCPlus4F,
    output logic [31:0] InstrD, PCD, PCPlus4D
);
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            InstrD   <= 32'h00000013; // Reset par hamesha NOP (addi x0,x0,0) dein, 0 nahi!
            PCD      <= 32'b0;
            PCPlus4D <= 32'b0;
        end else if (flush) begin
            InstrD   <= 32'h00000013;
            PCD      <= 32'b0;
            PCPlus4D <= 32'b0;
        end else if (en) begin // En true hone par hi write ho
            InstrD   <= InstrF;
            PCD      <= PCF;
            PCPlus4D <= PCPlus4F;
        end
    end
endmodule
