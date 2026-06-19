# rv32i-pipelined-cpu-with-cache

A 5-stage pipelined RISC-V RV32I processor with non-blocking instruction and data caches connected over AXI4, implemented in SystemVerilog and verified in Vivado XSim.

## Overview

This project implements a classic 5-stage in-order pipeline (Fetch → Decode → Execute → Memory → Writeback) for the RV32I base integer instruction set, backed by separate instruction and data caches that communicate with memory through an AXI4 interface. The caches are non-blocking, allowing the pipeline to continue issuing independent requests rather than stalling completely on every miss.

## Features

- **ISA**: RV32I base integer instruction set
- **Pipeline**: 5 stages — IF, ID, EX, MEM, WB
- **Hazard handling**: Full data forwarding (EX/MEM and MEM/WB) to resolve RAW hazards; pipeline stalls on load-use hazards and on branch resolution (static, no branch prediction — branches are resolved in EX/MEM before the next instruction is fetched down the resolved path)
- **Memory system**: Separate non-blocking I-cache and D-cache, each set-associative with a write-back policy on the D-cache *(confirm associativity, line size, and capacity for your design — see Cache Configuration below)*
- **Bus interface**: AXI4 master interface from the cache subsystem to memory
- **Verification**: Self-checking testbenches simulated in Vivado XSim

## Architecture

```
        ┌──────┐   ┌──────┐   ┌──────┐   ┌──────┐   ┌──────┐
        │  IF  │──▶│  ID  │──▶│  EX  │──▶│ MEM  │──▶│  WB  │
        └──┬───┘   └──────┘   └──┬───┘   └──┬───┘   └──────┘
           │                     │           │
           ▼                     ▼           ▼
       ┌────────┐           forwarding   ┌────────┐
       │ I-Cache│                        │ D-Cache│
       └───┬────┘                        └───┬────┘
           │                                  │
           └───────────────┬──────────────────┘
                            ▼
                      AXI4 Interconnect
                            ▼
                          Memory
```

- **IF**: Fetches instructions from the I-cache; stalls on I-cache miss.
- **ID**: Decodes instruction, reads register file, detects hazards.
- **EX**: ALU operations, branch/jump resolution, address generation.
- **MEM**: Issues loads/stores to the D-cache; non-blocking misses allow later independent instructions to proceed where possible.
- **WB**: Writes results back to the register file.

## Hazard Handling

- **Data hazards**: Resolved via full forwarding from EX/MEM and MEM/WB pipeline registers back into EX. Load-use hazards (where a dependent instruction immediately follows a load) still require a single-cycle stall since the loaded value isn't available until MEM.
- **Control hazards**: Handled statically — there is no branch predictor. The pipeline stalls/flushes on branches and jumps until the target and outcome are resolved, then resumes fetch from the correct path.
- **Structural hazards**: Avoided by the non-blocking cache design, which lets independent memory requests proceed without forcing a full pipeline stall on every cache access.

## Cache Configuration

*(Fill in to match your implementation — placeholders below)*

| Parameter | I-Cache | D-Cache |
|---|---|---|
| Organization | Set-associative | Set-associative |
| Associativity | `N`-way | `N`-way |
| Line size | `XX` bytes | `XX` bytes |
| Capacity | `XX` KB | `XX` KB |
| Write policy | N/A (read-only) | Write-back, write-allocate |
| Replacement | LRU / random | LRU / random |
| Miss handling | Non-blocking | Non-blocking |

Both caches connect to main memory through a shared/separate AXI4 master port(s) *(specify which)*, using the AXI4 burst protocol for line fills and writebacks.

## Repository Structure

```
rv32i-pipelined-cpu-with-cache/
├── rtl/              # SystemVerilog source (pipeline stages, caches, AXI interface)
├── tb/               # Testbenches
├── sim/              # Simulation scripts / waveform configs
├── sw/               # Test programs / assembly used for verification
└── README.md
```

*(Update to reflect actual directory layout)*

## Verification

The design is verified using self-checking testbenches run in Vivado XSim, covering:
- ISA-level instruction tests (arithmetic, logical, branch, load/store)
- Pipeline hazard scenarios (RAW dependencies, load-use stalls, branch flushes)
- Cache behavior (hits, misses, non-blocking miss handling, write-back eviction)
- AXI4 transaction correctness

## Status / Roadmap

- [x] 5-stage in-order pipeline
- [x] Data forwarding and hazard stalls
- [x] Non-blocking I-cache and D-cache
- [x] AXI4 memory interface
- [ ] Branch prediction
- [ ] Exception / interrupt support
- [ ] FPGA synthesis and on-board validation

## License

*(Add license information)*
