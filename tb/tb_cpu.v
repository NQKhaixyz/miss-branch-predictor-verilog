`timescale 1ns/1ps

// The reference traces are generated from the machine words by an independent
// interpreter. Compare architectural effects at retirement and also verify
// each store on the actual memory bus, where a wrong-path store could escape.
module tb_cpu;
    parameter MODE = 3;          // 0..3: pipeline modes, 4: single-cycle reference
    parameter INDEX_BITS = 6;
    localparam WORDS = 1024;
    localparam GUARD_CYCLES = 6;

    reg clk = 0;
    reg reset = 1;
    always #5 clk = ~clk;

    wire [31:0] imem_addr, imem_rdata;
    wire [31:0] dmem_addr, dmem_wdata, dmem_rdata;
    wire dmem_we;
    wire retire_valid, retire_reg_we, retire_mem_we;
    wire [4:0] retire_rd;
    wire [31:0] retire_pc, retire_reg_data, retire_mem_addr, retire_mem_data;
    wire branch_valid, actual_taken, raw_pred_taken, effective_pred_taken;
    wire pred_btb_hit, flush, branch_stall, load_stall;
    wire [31:0] branch_pc, pred_next_pc, actual_next_pc;

    reg [31:0] imem [0:WORDS-1];
    reg [31:0] dmem [0:WORDS-1];
    reg [31:0] expected_dmem [0:WORDS-1];
    assign imem_rdata = (imem_addr[1:0] == 0 && imem_addr[31:2] < WORDS)
        ? imem[imem_addr[31:2]] : 32'hffffffff;
    assign dmem_rdata = (dmem_addr[1:0] == 0 && dmem_addr[31:2] < WORDS)
        ? dmem[dmem_addr[31:2]] : 32'hxxxxxxxx;

    generate
        if (MODE == 4) begin : single
            mips_single_cycle dut (
                .clk(clk), .reset(reset),
                .imem_addr(imem_addr), .imem_rdata(imem_rdata),
                .dmem_addr(dmem_addr), .dmem_rdata(dmem_rdata),
                .dmem_wdata(dmem_wdata), .dmem_we(dmem_we),
                .retire_valid(retire_valid), .retire_pc(retire_pc),
                .retire_reg_we(retire_reg_we), .retire_rd(retire_rd),
                .retire_reg_data(retire_reg_data),
                .retire_mem_we(retire_mem_we), .retire_mem_addr(retire_mem_addr),
                .retire_mem_data(retire_mem_data)
            );
            assign branch_valid = 0;
            assign actual_taken = 0;
            assign raw_pred_taken = 0;
            assign effective_pred_taken = 0;
            assign pred_btb_hit = 0;
            assign branch_pc = 0;
            assign pred_next_pc = 0;
            assign actual_next_pc = 0;
            assign flush = 0;
            assign branch_stall = 0;
            assign load_stall = 0;
        end else begin : pipe
            mips_pipeline #(.MODE(MODE), .INDEX_BITS(INDEX_BITS)) dut (
                .clk(clk), .reset(reset),
                .imem_addr(imem_addr), .imem_rdata(imem_rdata),
                .dmem_addr(dmem_addr), .dmem_rdata(dmem_rdata),
                .dmem_wdata(dmem_wdata), .dmem_we(dmem_we),
                .retire_valid(retire_valid), .retire_pc(retire_pc),
                .retire_reg_we(retire_reg_we), .retire_rd(retire_rd),
                .retire_reg_data(retire_reg_data),
                .retire_mem_we(retire_mem_we), .retire_mem_addr(retire_mem_addr),
                .retire_mem_data(retire_mem_data),
                .branch_valid(branch_valid), .actual_taken(actual_taken),
                .raw_pred_taken(raw_pred_taken),
                .effective_pred_taken(effective_pred_taken),
                .pred_btb_hit(pred_btb_hit), .branch_pc(branch_pc),
                .pred_next_pc(pred_next_pc), .actual_next_pc(actual_next_pc),
                .flush(flush), .branch_stall(branch_stall), .load_stall(load_stall)
            );
        end
    endgenerate

    reg [8*1024-1:0] imem_path, dmem_path, trace_path, branch_path;
    reg [8*1024-1:0] final_dmem_path, vcd_path;
    reg check_final_dmem;
    integer trace_fd, store_fd, branch_fd;
    integer expected_count, max_cycles, i;
    integer cycles = 0;
    integer retired = 0;
    integer branches = 0;
    integer dir_correct = 0;
    integer effective_correct = 0;
    integer next_pc_correct = 0;
    integer btb_hits = 0;
    integer flushes = 0;
    integer load_stalls = 0;
    integer branch_stalls = 0;
    integer guard_left = 0;
    integer stores = 0;

    reg store_pending;
    reg [31:0] expected_store_addr, expected_store_data;

    // A store reaches the pipeline bus in MEM, one cycle before WB. Scan a
    // second copy of the trace so the bus and retire streams stay independent.
    task advance_expected_store;
        integer fields;
        reg [31:0] ignored_pc, ignored_reg_data;
        reg ignored_reg_we, row_mem_we;
        reg [4:0] ignored_rd;
        begin
            store_pending = 0;
            fields = 7;
            while (!store_pending && fields == 7) begin
                fields = $fscanf(store_fd, "%h %h %h %h %h %h %h",
                    ignored_pc, ignored_reg_we, ignored_rd, ignored_reg_data,
                    row_mem_we, expected_store_addr, expected_store_data);
                if (fields == 7)
                    store_pending = row_mem_we;
                else if (fields > 0)
                    $fatal(1, "Malformed store reference row (%0d fields)", fields);
            end
        end
    endtask

    initial begin
        if (MODE < 0 || MODE > 4)
            $fatal(1, "MODE must be 0..4");
        if (!$value$plusargs("IMEM=%s", imem_path) ||
            !$value$plusargs("DMEM=%s", dmem_path) ||
            !$value$plusargs("TRACE=%s", trace_path) ||
            !$value$plusargs("BRANCH=%s", branch_path) ||
            !$value$plusargs("COUNT=%d", expected_count))
            $fatal(1, "Required arguments: +IMEM= +DMEM= +TRACE= +BRANCH= +COUNT=");
        if (expected_count <= 0)
            $fatal(1, "COUNT must be positive");
        if (!$value$plusargs("MAX_CYCLES=%d", max_cycles))
            max_cycles = 8 * expected_count + 32;
        if (max_cycles <= 0)
            $fatal(1, "MAX_CYCLES must be positive");

        $readmemh(imem_path, imem);
        $readmemh(dmem_path, dmem);
        check_final_dmem = $value$plusargs("FINAL_DMEM=%s", final_dmem_path);
        if (check_final_dmem)
            $readmemh(final_dmem_path, expected_dmem);
        for (i = 0; i < WORDS; i = i + 1) begin
            if ((^imem[i]) === 1'bx || (^dmem[i]) === 1'bx ||
                (check_final_dmem && (^expected_dmem[i]) === 1'bx))
                $fatal(1, "Invalid or missing word %0d in a memory image", i);
        end
        trace_fd = $fopen(trace_path, "r");
        store_fd = $fopen(trace_path, "r");
        branch_fd = $fopen(branch_path, "r");
        if (!trace_fd || !store_fd || !branch_fd)
            $fatal(1, "Cannot open a reference trace");
        advance_expected_store;
        if ($value$plusargs("VCD=%s", vcd_path)) begin
            $dumpfile(vcd_path);
            // Record CPU signals for the demo without dumping host file paths.
            $dumpvars(0, clk, reset, imem_addr, imem_rdata, dmem_addr,
                      dmem_rdata, dmem_wdata, dmem_we, retire_valid, retire_pc,
                      retire_reg_we, retire_rd, retire_reg_data, retire_mem_we,
                      retire_mem_addr, retire_mem_data, branch_valid, branch_pc,
                      actual_taken, raw_pred_taken, effective_pred_taken,
                      pred_btb_hit, pred_next_pc, actual_next_pc, flush,
                      branch_stall, load_stall, cycles, retired, branches);
        end

        repeat (2) @(negedge clk);
        reset = 0;
    end

    task check_retirement;
        integer fields;
        reg [31:0] ref_pc, ref_reg_data, ref_mem_addr, ref_mem_data;
        reg ref_reg_we, ref_mem_we;
        reg [4:0] ref_rd;
        begin
            fields = $fscanf(trace_fd, "%h %h %h %h %h %h %h",
                ref_pc, ref_reg_we, ref_rd, ref_reg_data,
                ref_mem_we, ref_mem_addr, ref_mem_data);
            if (fields != 7)
                $fatal(1, "Retirement trace ended or malformed at instruction %0d",
                    retired + 1);
            if (retire_pc !== ref_pc)
                $fatal(1, "Cycle %0d retire %0d: expected PC=%08h, got %08h",
                    cycles, retired + 1, ref_pc, retire_pc);
            if (retire_reg_we !== ref_reg_we ||
                (ref_reg_we && {retire_rd, retire_reg_data} !== {ref_rd, ref_reg_data}))
                $fatal(1, "PC=%08h: expected reg write=%b r%0d=%08h, got %b r%0d=%08h",
                    retire_pc, ref_reg_we, ref_rd, ref_reg_data,
                    retire_reg_we, retire_rd, retire_reg_data);
            if (retire_mem_we !== ref_mem_we ||
                (ref_mem_we && {retire_mem_addr, retire_mem_data} !==
                    {ref_mem_addr, ref_mem_data}))
                $fatal(1, "PC=%08h: expected store=%b [%08h]=%08h, got %b [%08h]=%08h",
                    retire_pc, ref_mem_we, ref_mem_addr, ref_mem_data,
                    retire_mem_we, retire_mem_addr, retire_mem_data);
        end
    endtask

    task check_branch;
        integer fields;
        reg [31:0] ref_pc, ref_next_pc;
        reg ref_taken;
        begin
            fields = $fscanf(branch_fd, "%h %h %h", ref_pc, ref_taken, ref_next_pc);
            if (fields != 3)
                $fatal(1, "Extra resolved branch at PC=%08h or malformed branch trace",
                    branch_pc);
            if ({branch_pc, actual_taken, actual_next_pc} !==
                {ref_pc, ref_taken, ref_next_pc})
                $fatal(1, "Branch %0d: expected PC=%08h taken=%b next=%08h, got %08h %b %08h",
                    branches + 1, ref_pc, ref_taken, ref_next_pc,
                    branch_pc, actual_taken, actual_next_pc);
            branches = branches + 1;

            if (MODE != 0) begin
                if ((^{raw_pred_taken, effective_pred_taken, pred_btb_hit,
                    pred_next_pc}) === 1'bx)
                    $fatal(1, "Unknown prediction at PC=%08h", branch_pc);
                if (MODE == 1 && {raw_pred_taken, effective_pred_taken, pred_btb_hit} != 0)
                    $fatal(1, "Static not-taken mode must use sequential fetch");
                if (effective_pred_taken !== (raw_pred_taken && pred_btb_hit) ||
                    (!effective_pred_taken && pred_next_pc != branch_pc + 32'd4))
                    $fatal(1, "Prediction metadata disagrees with fetch at PC=%08h", branch_pc);
                if (raw_pred_taken == ref_taken) dir_correct = dir_correct + 1;
                if (effective_pred_taken == ref_taken)
                    effective_correct = effective_correct + 1;
                if (pred_next_pc == ref_next_pc) next_pc_correct = next_pc_correct + 1;
                if (pred_btb_hit) btb_hits = btb_hits + 1;
                if (flush !== (pred_next_pc != ref_next_pc))
                    $fatal(1, "Incorrect flush at PC=%08h, predicted=%08h actual=%08h",
                        branch_pc, pred_next_pc, ref_next_pc);
            end
        end
    endtask

    task finish_check;
        integer word_index;
        reg [31:0] extra_pc;
        begin
            if ($fscanf(trace_fd, "%h", extra_pc) > 0)
                $fatal(1, "COUNT smaller than retirement trace, next PC=%08h", extra_pc);
            if (MODE != 4 && $fscanf(branch_fd, "%h", extra_pc) > 0)
                $fatal(1, "Missing resolved branch at PC=%08h", extra_pc);
            if (store_pending)
                $fatal(1, "Missing memory bus store [%08h]=%08h",
                    expected_store_addr, expected_store_data);
            if (check_final_dmem)
                for (word_index = 0; word_index < WORDS; word_index = word_index + 1)
                    if (dmem[word_index] !== expected_dmem[word_index])
                        $fatal(1, "DMEM word %0d: expected %08h, got %08h",
                            word_index, expected_dmem[word_index], dmem[word_index]);
            if (MODE == 0 && branch_stalls != 2 * branches)
                $fatal(1, "Blocking mode must lose two fetch slots per branch");
            if (MODE >= 1 && MODE <= 3 && flushes != branches - next_pc_correct)
                $fatal(1, "Flush count must match wrong next PCs");

            $fclose(trace_fd);
            $fclose(store_fd);
            $fclose(branch_fd);
            $display("RESULT cycles=%0d retired=%0d branches=%0d dir_correct=%0d effective_correct=%0d next_pc_correct=%0d btb_hits=%0d flushes=%0d load_stalls=%0d branch_stalls=%0d stores=%0d",
                cycles, retired, branches, dir_correct, effective_correct,
                next_pc_correct, btb_hits, flushes, load_stalls, branch_stalls, stores);
            $finish;
        end
    endtask

    always @(posedge clk) begin
        if (!reset) begin
            if ((^{retire_valid, dmem_we, branch_valid, flush,
                load_stall, branch_stall}) === 1'bx)
                $fatal(1, "Unknown control signal at cycle %0d", cycles + 1);

            if (retired == expected_count) begin
                if (retire_valid || dmem_we || branch_valid || flush ||
                    load_stall || branch_stall)
                    $fatal(1, "Unexpected activity after final retirement at PC=%08h",
                        retire_pc);
                guard_left = guard_left - 1;
                if (guard_left == 0)
                    finish_check;
            end else begin
                cycles = cycles + 1;
                if (cycles > max_cycles)
                    $fatal(1, "Timeout: %0d/%0d retirements; fetch PC=%08h",
                        retired, expected_count, imem_addr);

                if (dmem_we) begin
                    if (!store_pending || dmem_addr !== expected_store_addr ||
                        dmem_wdata !== expected_store_data)
                        $fatal(1, "Cycle %0d unexpected store [%08h]=%08h, expected [%08h]=%08h pending=%b",
                            cycles, dmem_addr, dmem_wdata,
                            expected_store_addr, expected_store_data, store_pending);
                    if (dmem_addr[1:0] != 0 || dmem_addr[31:2] >= WORDS)
                        $fatal(1, "Store outside aligned DMEM: %08h", dmem_addr);
                    dmem[dmem_addr[31:2]] <= dmem_wdata;
                    stores = stores + 1;
                    advance_expected_store;
                end
                if (branch_valid) check_branch;
                if (flush) begin
                    if (!branch_valid || MODE == 0)
                        $fatal(1, "Unexpected flush outside a predictive branch");
                    flushes = flushes + 1;
                end
                if (load_stall) load_stalls = load_stalls + 1;
                if (branch_stall) branch_stalls = branch_stalls + 1;
                if (retire_valid) begin
                    check_retirement;
                    retired = retired + 1;
                    if (retired == expected_count)
                        guard_left = GUARD_CYCLES;
                end
            end
        end
    end
endmodule
