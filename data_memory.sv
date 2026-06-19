`timescale 1ns / 1ps

module top(
    input logic clk,
    input logic reset
);

/////////////////////////////////////////////////////
// IF STAGE
/////////////////////////////////////////////////////

logic [31:0] PCF;
logic [31:0] InstrF;
logic [31:0] PCNext, PCPlus4F;

logic StallF, StallD, FlushE;

/////////////////////////////////////////////////////
// ID STAGE
/////////////////////////////////////////////////////

logic [31:0] InstrD, PCD;

logic [4:0] Rs1D, Rs2D;

/////////////////////////////////////////////////////
// EX STAGE
/////////////////////////////////////////////////////

logic [31:0] RD1E, RD2E;
logic [4:0] rs1E, rs2E, rdE;

logic MemReadE;
logic RegWriteE;
logic JumpE, BranchE;

logic ALUSrcE;
logic [2:0] ALUControlE;

logic ZeroE;
logic PCSrcE;

/////////////////////////////////////////////////////
// MEM STAGE
/////////////////////////////////////////////////////

logic RegWriteM;
logic MemWriteM;
logic [4:0] rdM;

logic [31:0] ALUResultM;
logic [31:0] RD2M;
logic [31:0] ReadDataM;

logic [2:0] funct3M;

/////////////////////////////////////////////////////
// WB STAGE
/////////////////////////////////////////////////////

logic RegWriteW;
logic [4:0] rdW;
logic [31:0] ResultW;

/////////////////////////////////////////////////////
// CACHE SIGNALS
/////////////////////////////////////////////////////

logic icache_stall, icache_hit;
logic icache_mem_req;
logic [31:0] icache_mem_addr;
logic [31:0] icache_mem_rdata;

logic dcache_stall, dcache_hit;
logic dcache_mem_req, dcache_mem_we;
logic [3:0] dcache_mem_be;
logic [31:0] dcache_mem_addr;
logic [31:0] dcache_mem_wdata;
logic [31:0] dcache_mem_rdata;
logic dcache_mem_ready;

/////////////////////////////////////////////////////
// PC UPDATE
/////////////////////////////////////////////////////

Adder PC4(.A(PCF), .B(32'd4), .Sum(PCPlus4F));

mux2 PCMux(
    .d0(PCPlus4F),
    .d1(ALUResultM),   // branch target (simplified placeholder)
    .s(PCSrcE),
    .y(PCNext)
);

program_counter PC(
    .clk(clk),
    .reset(reset),
    .en(~StallF),
    .PCNext(PCNext),
    .PC(PCF)
);

/////////////////////////////////////////////////////
// I-CACHE
/////////////////////////////////////////////////////

icache instruction_cache(
    .clk(clk),
    .rst(reset),
    .cpu_addr(PCF),
    .cpu_instr(InstrF),
    .hit(icache_hit),
    .stall(icache_stall),
    .mem_req(icache_mem_req),
    .mem_addr(icache_mem_addr),
    .mem_rdata(icache_mem_rdata),
    .mem_ready(1'b1)
);

instr_mem instruction_memory(
    .A(icache_mem_addr),
    .RD(icache_mem_rdata)
);

/////////////////////////////////////////////////////
// IF/ID
/////////////////////////////////////////////////////

IF_ID IF_ID(
    .clk(clk),
    .reset(reset),
    .flush(1'b0),
    .en(~StallD),
    .InstrF(InstrF),
    .PCF(PCF),
    .InstrD(InstrD),
    .PCD(PCD)
);

assign Rs1D = InstrD[19:15];
assign Rs2D = InstrD[24:20];

/////////////////////////////////////////////////////
// REGISTER FILE
/////////////////////////////////////////////////////

register_file RF(
    .clk(clk),
    .A1(Rs1D),
    .A2(Rs2D),
    .A3(rdW),
    .wd3(ResultW),
    .we(RegWriteW),
    .rd1(RD1E),
    .rd2(RD2E)
);

/////////////////////////////////////////////////////
// CONTROL UNIT (assumed exists)
/////////////////////////////////////////////////////

control_unit CU(
    .op(InstrD[6:0]),
    .funct3(InstrD[14:12]),
    .funct7b5(InstrD[30]),
    .Branch(BranchD),
    .Jump(JumpD),
    .ALUSrc(ALUSrcD),
    .ALUControl(ALUControlD),
    .MemWrite(MemWriteD),
    .RegWrite(RegWriteD)
);

/////////////////////////////////////////////////////
// HAZARD UNIT
/////////////////////////////////////////////////////

rvhazard hazard(
    .clk(clk),
    .reset(reset),

    .Rs1D(Rs1D),
    .Rs2D(Rs2D),

    .RdE(rdE),
    .MemReadE(MemReadE),

    .RdM(rdM),
    .RegWriteM(RegWriteM),

    .PCSrcE(PCSrcE),

    .icache_stall(icache_stall),
    .dcache_stall(dcache_stall),

    .StallF(StallF),
    .StallD(StallD),
    .FlushE(FlushE)
);

/////////////////////////////////////////////////////
// EX (simplified ALU)
/////////////////////////////////////////////////////

ALU alu(
    .SrcA(RD1E),
    .SrcB(RD2E),
    .ALUControl(ALUControlE),
    .ALUResult(ALUResultM),
    .Zero(ZeroE)
);

/////////////////////////////////////////////////////
// BRANCH CONTROL
/////////////////////////////////////////////////////

assign PCSrcE = BranchE & ZeroE;

/////////////////////////////////////////////////////
// D-CACHE
/////////////////////////////////////////////////////

dcache data_cache(
    .clk(clk),
    .rst(reset),

    .mem_read(MemWriteM),
    .mem_write(MemWriteM),

    .cpu_addr(ALUResultM),
    .cpu_wdata(RD2M),
    .cpu_rdata(ReadDataM),

    .hit(dcache_hit),
    .stall(dcache_stall),

    .mem_req(dcache_mem_req),
    .mem_we(dcache_mem_we),
    .mem_be(dcache_mem_be),
    .mem_addr(dcache_mem_addr),
    .mem_wdata(dcache_mem_wdata),
    .mem_rdata(dcache_mem_rdata),
    .mem_ready(dcache_mem_ready)
);

/////////////////////////////////////////////////////
// WB
/////////////////////////////////////////////////////

mux3to1 WBmux(
    .d0(ALUResultM),
    .d1(ReadDataM),
    .d2(PCPlus4F),
    .s(ResultSrcM),
    .y(ResultW)
);

endmodule