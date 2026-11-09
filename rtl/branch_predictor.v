`timescale 1ns/1ps
`default_nettype none

// Direct-mapped BTB and untagged direction history. Lookup is combinational;
// training is sampled on the rising edge from a resolved, valid branch.
module branch_predictor #(
    parameter MODE = 3,
    parameter INDEX_BITS = 6
) (
    input  wire        clk,
    input  wire        reset,
    input  wire [31:0] lookup_pc,
    output wire        raw_taken,
    output wire        hit,
    output wire        pred_taken,
    output wire [31:0] pred_next_pc,
    input  wire        update_valid,
    input  wire [31:0] update_pc,
    input  wire        update_taken,
    input  wire [31:0] update_target
);
    localparam ENTRIES = 1 << INDEX_BITS;
    localparam TAG_BITS = 30 - INDEX_BITS;

    generate
        if (MODE == 2 || MODE == 3) begin : dynamic_predictor
            wire [INDEX_BITS-1:0] lookup_index = lookup_pc[INDEX_BITS+1:2];
            wire [INDEX_BITS-1:0] update_index = update_pc[INDEX_BITS+1:2];
            wire [TAG_BITS-1:0] lookup_tag = lookup_pc[31:INDEX_BITS+2];
            reg [ENTRIES-1:0] btb_valid;
            reg [TAG_BITS-1:0] btb_tag [0:ENTRIES-1];
            reg [31:0] btb_target [0:ENTRIES-1];

            assign hit = btb_valid[lookup_index] && (btb_tag[lookup_index] == lookup_tag);
            assign pred_taken = hit && raw_taken;
            assign pred_next_pc = pred_taken ? btb_target[lookup_index] : lookup_pc + 32'd4;

            always @(posedge clk) begin
                if (reset) begin
                    btb_valid <= {ENTRIES{1'b0}};
                end else if (update_valid) begin
                    // Even a not-taken conditional branch has a known target.
                    btb_valid[update_index] <= 1'b1;
                    btb_tag[update_index] <= update_pc[31:INDEX_BITS+2];
                    btb_target[update_index] <= update_target;
                end
            end

            if (MODE == 2) begin : last_outcome
                reg [ENTRIES-1:0] history;
                assign raw_taken = history[lookup_index];

                always @(posedge clk) begin
                    if (reset)
                        history <= {ENTRIES{1'b0}};
                    else if (update_valid)
                        history[update_index] <= update_taken;
                end
            end else begin : saturating_counter
                reg [1:0] history [0:ENTRIES-1];
                integer entry;
                assign raw_taken = history[lookup_index][1];

                always @(posedge clk) begin
                    if (reset) begin
                        for (entry = 0; entry < ENTRIES; entry = entry + 1)
                            history[entry] <= 2'b01; // Weakly not taken
                    end else if (update_valid) begin
                        if (update_taken && history[update_index] != 2'b11)
                            history[update_index] <= history[update_index] + 2'd1;
                        else if (!update_taken && history[update_index] != 2'b00)
                            history[update_index] <= history[update_index] - 2'd1;
                    end
                end
            end
        end else begin : sequential_fetch
            assign raw_taken = 1'b0;
            assign hit = 1'b0;
            assign pred_taken = 1'b0;
            assign pred_next_pc = lookup_pc + 32'd4;
        end
    endgenerate
endmodule

`default_nettype wire
