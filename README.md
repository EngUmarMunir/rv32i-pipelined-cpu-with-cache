**rv32i-pipelined-cpu-with-cache**

A 5-stage pipelined RISC-V RV32I processor with non-blocking instruction and data caches connected over AXI4, implemented in SystemVerilog and verified in Vivado XSim.

This project implements a classic 5-stage in-order pipeline (Fetch → Decode → Execute → Memory → Writeback) for the RV32I base integer instruction set, backed by separate instruction and data caches that communicate with memory through an AXI4-style burst interface. Both caches are non-blocking: a miss on one line doesn't prevent a hit on another line from being served the same cycle ("hit-under-miss"), and the data cache additionally supports early-forwarding of the requested word straight off the refill bus before the line finishes filling.

**Features**

- ISA: RV32I base integer instruction set
- Pipeline: 5 stages — IF, ID, EX, MEM, WB
- Hazard handling: full data forwarding (EX/MEM and MEM/WB) to resolve RAW hazards; pipeline stalls on load-use hazards and on branch resolution (static, no branch prediction — branches are resolved before the next instruction is committed down the resolved path)
- Memory system: separate non-blocking I-cache and D-cache (see Cache Configuration below)
- Bus interface: burst-capable memory interface (AXI4-style: req/ready handshake, multi-beat rdata with rvalid/rlast) from each cache to memory
- Verification: self-checking testbenches simulated in Vivado XSim

**Architecture**

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

IF fetches instructions from the I-cache and stalls (`busy`) on an I-cache miss. ID decodes the instruction, reads the register file, and detects hazards. EX performs ALU operations, branch/jump resolution, and address generation. MEM issues loads/stores to the D-cache; non-blocking misses allow a hit on a different line to be served in the same cycle. WB writes results back to the register file.

**Hazard handling**

Data hazards are resolved via full forwarding from EX/MEM and MEM/WB pipeline registers back into EX. Load-use hazards, where a dependent instruction immediately follows a load, still require a stall since the loaded value isn't available until MEM. Control hazards are handled statically — there is no branch predictor. The pipeline stalls/flushes on branches and jumps until the target and outcome are resolved, then resumes fetch from the correct path. Structural hazards are mitigated by the non-blocking cache design: a miss on one cache line does not force a stall on a CPU access that hits a different, already-valid line.

**Cache configuration**

Parameters below are taken directly from the RTL (`icache_nonblocking`, `dcache_nonblocking`).

| Parameter | I-Cache | D-Cache |
|---|---|---|
| Organization | Direct-mapped | Direct-mapped |
| Lines | 64 | 16 |
| Index bits | 6 | 4 |
| Tag bits | 22 | 24 |
| Line size | 4 words (16 bytes) | 4 words (16 bytes) |
| Capacity | 1 KB (64 × 16 B) | 256 B (16 × 16 B) |
| Access type | Read-only | Read/write, byte/half/word (`funct3`-decoded) |
| Write policy | N/A | Write-through, write-allocate on miss |
| Replacement | N/A (direct-mapped) | N/A (direct-mapped) |
| Miss handling | Non-blocking (hit-under-miss) | Non-blocking (hit-under-miss + early-forward) |

Address breakdown — I-cache: `addr[31:10]` = tag, `addr[9:4]` = index, `addr[3:2]` = word offset. D-cache: `addr[31:8]` = tag, `addr[7:4]` = index, `addr[3:2]` = word offset, `addr[1:0]` = byte offset.

The D-cache is write-through, not write-back — every write hit updates the cache line and immediately issues a single-beat write-through transaction to memory (`WRITE_HIT_WAIT`); there is no dirty bit or deferred writeback on eviction. A write miss triggers write-allocate: the line is fetched via the same burst-refill path as a read miss, the pending store is merged into the arriving beat, and a write-through to memory follows (`WRITE_ALLOC_WAIT`).

For non-blocking behavior, the I-cache serves a CPU access to a different, already-valid line as a normal hit even while another line is being refilled, and forwards the requested word directly off the refill bus the cycle it arrives rather than waiting for the whole line to finish filling. The D-cache behaves the same way for reads, plus an early-forward path that returns the requested word straight off the incoming refill beat, unless that exact beat is also the target of a pending merged store, in which case it waits one more cycle for the merge to complete.

**Memory interface**

Each cache drives a simple burst request/response interface rather than raw AXI4 channels:

| Signal | Direction | Meaning |
|---|---|---|
| `mem_req` | cache → mem | Burst request, held high until `mem_ready` |
| `mem_addr` | cache → mem | Line-aligned burst address (reads) or single-beat byte address (D-cache write-through) |
| `mem_burst_len` | cache → mem | Number of words requested (4 for line fills, 1 for write-through) |
| `mem_we` / `mem_be` / `mem_wdata` | cache → mem | Write enable, byte-enables, and write data (D-cache only) |
| `mem_rdata` / `mem_rvalid` / `mem_rlast` | mem → cache | One beat of burst data per cycle, with `rlast` marking the final beat |
| `mem_ready` | mem → cache | One-cycle pulse acknowledging that `mem_req` was accepted |

This interface is intended to sit behind an AXI4 master adapter (`cache_axi4_master` in the codebase) that translates it to AXI4 read/write address and data channels.

**Repository structure**

```
rv32i-pipelined-cpu-with-cache/
├── rtl/              # SystemVerilog source (pipeline stages, caches, AXI interface)
├── tb/               # Testbenches
├── sim/              # Simulation scripts / waveform configs
├── sw/               # Test programs / assembly used for verification
└── README.md
```


**Verification**

The design is verified using self-checking testbenches run in Vivado XSim, covering ISA-level instruction tests (arithmetic, logical, branch, load/store), pipeline hazard scenarios (RAW dependencies, load-use stalls, branch flushes), cache behavior (hits, misses, hit-under-miss, write-through, write-allocate), and burst/AXI4 transaction correctness.

**Status / roadmap**

- [x] 5-stage in-order pipeline
- [x] Data forwarding and hazard stalls
- [x] Non-blocking, direct-mapped I-cache and D-cache
- [x] Burst memory interface / AXI4 master adapter
- [ ] Branch prediction
- [ ] Set-associative caches
- [ ] Exception / interrupt support
- [ ] FPGA synthesis and on-board validation

**License**

(Add license information.)
