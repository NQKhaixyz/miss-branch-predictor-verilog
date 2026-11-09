`timescale 1ns/1ps

module tb_predictor;
    localparam A = 32'h00000100;
    localparam B = 32'h00000110; // A and B share an index, with different tags.
    localparam C = 32'h00000104;
    localparam A_TARGET = 32'h00000080;
    localparam B_TARGET = 32'h00000180;
    localparam C_TARGET = 32'h000001e0;

    reg clk = 0;
    reg reset = 1;
    reg [31:0] lookup_pc = A;
    reg update_valid = 0;
    reg [31:0] update_pc = 0, update_target = 0;
    reg update_taken = 0;
    wire raw_1, hit_1, taken_1, raw_2, hit_2, taken_2;
    wire [31:0] next_1, next_2;
    reg [8*1024-1:0] vcd_path;
    always #5 clk = ~clk;

    branch_predictor #(.MODE(2), .INDEX_BITS(2)) one_bit (
        .clk(clk), .reset(reset), .lookup_pc(lookup_pc),
        .raw_taken(raw_1), .hit(hit_1), .pred_taken(taken_1),
        .pred_next_pc(next_1), .update_valid(update_valid),
        .update_pc(update_pc), .update_taken(update_taken),
        .update_target(update_target)
    );
    branch_predictor #(.MODE(3), .INDEX_BITS(2)) two_bit (
        .clk(clk), .reset(reset), .lookup_pc(lookup_pc),
        .raw_taken(raw_2), .hit(hit_2), .pred_taken(taken_2),
        .pred_next_pc(next_2), .update_valid(update_valid),
        .update_pc(update_pc), .update_taken(update_taken),
        .update_target(update_target)
    );
    // A = 0x100 maps to index zero for this unit test.
    wire [1:0] state_a = two_bit.dynamic_predictor.saturating_counter.history[0];

    task expect_lookup;
        input [8*80-1:0] label;
        input expected_raw_1, expected_raw_2, expected_hit;
        input [31:0] target;
        reg expected_taken_1, expected_taken_2;
        reg [31:0] expected_next_1, expected_next_2;
        begin
            #1;
            expected_taken_1 = expected_raw_1 && expected_hit;
            expected_taken_2 = expected_raw_2 && expected_hit;
            expected_next_1 = expected_taken_1 ? target : lookup_pc + 4;
            expected_next_2 = expected_taken_2 ? target : lookup_pc + 4;
            if ({raw_1, hit_1, taken_1, next_1} !==
                {expected_raw_1, expected_hit, expected_taken_1, expected_next_1})
                $fatal(1, "%0s at PC=%08h: 1-bit expected raw/hit/taken=%b%b%b next=%08h, got %b%b%b %08h",
                    label, lookup_pc, expected_raw_1, expected_hit,
                    expected_taken_1, expected_next_1, raw_1, hit_1, taken_1, next_1);
            if ({raw_2, hit_2, taken_2, next_2} !==
                {expected_raw_2, expected_hit, expected_taken_2, expected_next_2})
                $fatal(1, "%0s at PC=%08h: 2-bit expected raw/hit/taken=%b%b%b next=%08h, got %b%b%b %08h",
                    label, lookup_pc, expected_raw_2, expected_hit,
                    expected_taken_2, expected_next_2, raw_2, hit_2, taken_2, next_2);
        end
    endtask

    task train;
        input [31:0] pc;
        input taken;
        input [31:0] target;
        begin
            @(negedge clk);
            update_valid = 1;
            update_pc = pc;
            update_taken = taken;
            update_target = target;
            @(posedge clk);
            #1;
            update_valid = 0;
        end
    endtask

    initial begin
        if ($value$plusargs("VCD=%s", vcd_path)) begin
            $dumpfile(vcd_path);
            $dumpvars(0, clk, reset, lookup_pc, update_valid, update_pc,
                      update_taken, update_target, raw_1, hit_1, taken_1, next_1,
                      raw_2, hit_2, taken_2, next_2, state_a);
        end
        repeat (2) @(negedge clk);
        reset = 0;
        expect_lookup("cold lookup", 0, 0, 0, A_TARGET);

        @(negedge clk);
        update_valid = 1;
        update_pc = A;
        update_taken = 1;
        update_target = A_TARGET;
        expect_lookup("same-index read before update edge", 0, 0, 0, A_TARGET);
        @(posedge clk);
        #1;
        update_valid = 0;
        expect_lookup("first taken after weak N reset", 1, 1, 1, A_TARGET);
        train(A, 1, A_TARGET);
        train(A, 1, A_TARGET);
        expect_lookup("taken saturation", 1, 1, 1, A_TARGET);
        train(A, 0, A_TARGET);
        expect_lookup("isolated exit does not flip 2-bit direction", 0, 1, 1, A_TARGET);
        train(A, 0, A_TARGET);
        expect_lookup("2-bit direction flips after second N", 0, 0, 1, A_TARGET);
        train(A, 0, A_TARGET);
        train(A, 0, A_TARGET);
        expect_lookup("not-taken saturation", 0, 0, 1, A_TARGET);
        train(A, 1, A_TARGET);
        expect_lookup("isolated taken does not flip 2-bit direction", 1, 0, 1, A_TARGET);
        train(A, 1, A_TARGET);
        expect_lookup("2-bit direction flips after second T", 1, 1, 1, A_TARGET);

        lookup_pc = B;
        expect_lookup("same BHT index but no matching BTB tag", 1, 1, 0, B_TARGET);
        train(B, 1, B_TARGET);
        expect_lookup("BTB replacement supplies B target", 1, 1, 1, B_TARGET);
        lookup_pc = A;
        expect_lookup("A is evicted but aliases the trained direction", 1, 1, 0, A_TARGET);

        lookup_pc = C;
        expect_lookup("another index stays cold", 0, 0, 0, C_TARGET);
        lookup_pc = B;
        train(C, 0, C_TARGET);
        expect_lookup("unrelated concurrent update preserves B", 1, 1, 1, B_TARGET);
        lookup_pc = C;
        expect_lookup("not-taken branch allocates its target", 0, 0, 1, C_TARGET);
        train(C, 1, C_TARGET);
        expect_lookup("1-bit predicts C target while 2-bit remains N", 1, 0, 1, C_TARGET);

        @(negedge clk);
        update_pc = B;
        update_target = A_TARGET;
        update_taken = 0;
        @(posedge clk);
        lookup_pc = B;
        expect_lookup("disabled update cannot alter B", 1, 1, 1, B_TARGET);

        @(negedge clk);
        reset = 1;
        @(negedge clk);
        reset = 0;
        expect_lookup("reset invalidates B and clears its direction", 0, 0, 0, B_TARGET);
        lookup_pc = C;
        expect_lookup("reset also invalidates independent C", 0, 0, 0, C_TARGET);
        $display("PASS predictor");
        $finish;
    end
endmodule
