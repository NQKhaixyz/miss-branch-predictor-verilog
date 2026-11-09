`timescale 1ns/1ps
`default_nettype none

module mips_pipeline #(
    parameter MODE = 3,
    parameter INDEX_BITS = 6
) (
    input  wire        clk,
    input  wire        reset,
    input  wire [31:0] imem_rdata,
    output wire [31:0] imem_addr,
    input  wire [31:0] dmem_rdata,
    output wire [31:0] dmem_addr,
    output wire [31:0] dmem_wdata,
    output wire        dmem_we,
    output wire        retire_valid,
    output wire [31:0] retire_pc,
    output wire        retire_reg_we,
    output wire [4:0]  retire_rd,
    output wire [31:0] retire_reg_data,
    output wire        retire_mem_we,
    output wire [31:0] retire_mem_addr,
    output wire [31:0] retire_mem_data,
    output wire        branch_valid,
    output wire        actual_taken,
    output wire        raw_pred_taken,
    output wire        effective_pred_taken,
    output wire        pred_btb_hit,
    output wire [31:0] branch_pc,
    output wire [31:0] pred_next_pc,
    output wire [31:0] actual_next_pc,
    output wire        flush,
    output wire        branch_stall,
    output wire        load_stall
);
    localparam STALL_ON_BRANCH = 0;

    // IF stage and IF/ID register
    reg [31:0] pc;
    reg        if_id_valid;
    reg [31:0] if_id_pc;
    reg [31:0] if_id_instruction;
    reg [31:0] if_id_pred_pc;
    reg        if_id_raw_taken;
    reg        if_id_pred_taken;
    reg        if_id_btb_hit;

    // ID/EX register. Keep prediction metadata with the instruction that
    // generated it, even when an intervening load-use hazard holds IF/ID.
    reg        id_ex_valid;
    reg [31:0] id_ex_pc;
    reg [31:0] id_ex_pred_pc;
    reg        id_ex_raw_taken;
    reg        id_ex_pred_taken;
    reg        id_ex_btb_hit;
    reg [4:0]  id_ex_rs;
    reg [4:0]  id_ex_rt;
    reg [4:0]  id_ex_shamt;
    reg [31:0] id_ex_rs_value;
    reg [31:0] id_ex_rt_value;
    reg [31:0] id_ex_immediate;
    reg [4:0]  id_ex_rd;
    reg [1:0]  id_ex_alu_op;
    reg        id_ex_use_immediate;
    reg        id_ex_reg_write;
    reg        id_ex_mem_read;
    reg        id_ex_mem_write;
    reg        id_ex_branch_eq;
    reg        id_ex_branch_ne;

    // EX/MEM register
    reg        ex_mem_valid;
    reg [31:0] ex_mem_pc;
    reg [31:0] ex_mem_result;
    reg [31:0] ex_mem_store_data;
    reg [4:0]  ex_mem_rd;
    reg        ex_mem_reg_write;
    reg        ex_mem_mem_read;
    reg        ex_mem_mem_write;

    // MEM/WB register
    reg        mem_wb_valid;
    reg [31:0] mem_wb_pc;
    reg [4:0]  mem_wb_rd;
    reg [31:0] mem_wb_data;
    reg        mem_wb_reg_write;
    reg        mem_wb_mem_write;
    reg [31:0] mem_wb_mem_addr;
    reg [31:0] mem_wb_mem_data;

    wire [31:0] fetch_next_pc;
    wire fetch_raw_taken;
    wire fetch_pred_taken;
    wire fetch_btb_hit;

    wire id_legal;
    wire id_use_rs;
    wire id_use_rt;
    wire id_use_immediate;
    wire id_reg_write;
    wire id_mem_read;
    wire id_mem_write;
    wire id_branch_eq;
    wire id_branch_ne;
    wire [1:0]  id_alu_op;
    wire [4:0]  id_rd;
    wire [31:0] id_immediate;
    wire [31:0] id_rs_value;
    wire [31:0] id_rt_value;
    wire [4:0] id_rs = if_id_instruction[25:21];
    wire [4:0] id_rt = if_id_instruction[20:16];
    wire id_valid = if_id_valid && id_legal;
    wire id_is_branch = id_valid && (id_branch_eq || id_branch_ne);

    wire [31:0] ex_rs_value;
    wire [31:0] ex_rt_value;
    wire [31:0] ex_result;
    wire [31:0] ex_fallthrough = id_ex_pc + 32'd4;
    wire [31:0] ex_target = ex_fallthrough + (id_ex_immediate << 2);
    wire ex_operands_equal = ex_rs_value == ex_rt_value;
    wire ex_mem_forward = ex_mem_valid && ex_mem_reg_write &&
                          !ex_mem_mem_read && ex_mem_rd != 5'd0;

    assign imem_addr = pc;
    assign dmem_addr = ex_mem_result;
    assign dmem_wdata = ex_mem_store_data;
    assign dmem_we = !reset && ex_mem_valid && ex_mem_mem_write;

    assign retire_valid = !reset && mem_wb_valid;
    assign retire_pc = mem_wb_pc;
    assign retire_reg_we = retire_valid && mem_wb_reg_write && mem_wb_rd != 5'd0;
    assign retire_rd = mem_wb_rd;
    assign retire_reg_data = mem_wb_data;
    assign retire_mem_we = retire_valid && mem_wb_mem_write;
    assign retire_mem_addr = mem_wb_mem_addr;
    assign retire_mem_data = mem_wb_mem_data;

    branch_predictor #(.MODE(MODE), .INDEX_BITS(INDEX_BITS)) predictor (
        .clk(clk), .reset(reset), .lookup_pc(pc),
        .raw_taken(fetch_raw_taken), .hit(fetch_btb_hit),
        .pred_taken(fetch_pred_taken), .pred_next_pc(fetch_next_pc),
        .update_valid(branch_valid), .update_pc(id_ex_pc),
        .update_taken(actual_taken), .update_target(ex_target)
    );

    mips_decode decode (
        .instruction(if_id_instruction), .legal(id_legal),
        .use_rs(id_use_rs), .use_rt(id_use_rt), .use_immediate(id_use_immediate),
        .reg_write(id_reg_write), .mem_read(id_mem_read), .mem_write(id_mem_write),
        .branch_eq(id_branch_eq), .branch_ne(id_branch_ne), .alu_op(id_alu_op),
        .destination(id_rd), .immediate(id_immediate)
    );

    mips_register_file rf (
        .clk(clk), .reset(reset), .rs(id_rs), .rt(id_rt),
        .rs_value(id_rs_value), .rt_value(id_rt_value),
        .write_enable(retire_reg_we), .write_rd(retire_rd), .write_data(retire_reg_data)
    );

    // The newest ready producer wins. The same forwarding paths handle
    // ALU operands, branch comparisons, and store address/data operands.
    assign ex_rs_value = (ex_mem_forward && ex_mem_rd == id_ex_rs) ? ex_mem_result :
                         (retire_reg_we && retire_rd == id_ex_rs) ? retire_reg_data :
                         id_ex_rs_value;
    assign ex_rt_value = (ex_mem_forward && ex_mem_rd == id_ex_rt) ? ex_mem_result :
                         (retire_reg_we && retire_rd == id_ex_rt) ? retire_reg_data :
                         id_ex_rt_value;

    mips_alu alu (
        .op(id_ex_alu_op), .lhs(ex_rs_value),
        .rhs(id_ex_use_immediate ? id_ex_immediate : ex_rt_value),
        .shift(id_ex_shamt), .result(ex_result)
    );

    assign branch_valid = !reset && id_ex_valid && (id_ex_branch_eq || id_ex_branch_ne);
    assign actual_taken = branch_valid &&
                          ((id_ex_branch_eq && ex_operands_equal) ||
                           (id_ex_branch_ne && !ex_operands_equal));
    assign branch_pc = id_ex_pc;
    assign raw_pred_taken = id_ex_raw_taken;
    assign effective_pred_taken = id_ex_pred_taken;
    assign pred_btb_hit = id_ex_btb_hit;
    assign pred_next_pc = id_ex_pred_pc;
    assign actual_next_pc = actual_taken ? ex_target : ex_fallthrough;

    assign load_stall = !reset && id_valid && id_ex_valid && id_ex_mem_read &&
                        id_ex_rd != 5'd0 &&
                        ((id_use_rs && id_rs == id_ex_rd) ||
                         (id_use_rt && id_rt == id_ex_rd));
    assign flush = MODE != STALL_ON_BRANCH && branch_valid && pred_next_pc != actual_next_pc;
    assign branch_stall = !reset && MODE == STALL_ON_BRANCH &&
                          (branch_valid || (id_is_branch && !load_stall));

    always @(posedge clk) begin
        if (reset) begin
            pc <= 32'd0;
            if_id_valid <= 1'b0;
            id_ex_valid <= 1'b0;
            ex_mem_valid <= 1'b0;
            mem_wb_valid <= 1'b0;
        end else begin
            // Older instructions continue through MEM and WB on all stalls
            // and redirects, including the branch currently resolving in EX.
            ex_mem_valid <= id_ex_valid;
            ex_mem_pc <= id_ex_pc;
            ex_mem_result <= ex_result;
            ex_mem_store_data <= ex_rt_value;
            ex_mem_rd <= id_ex_rd;
            ex_mem_reg_write <= id_ex_reg_write;
            ex_mem_mem_read <= id_ex_mem_read;
            ex_mem_mem_write <= id_ex_mem_write;

            mem_wb_valid <= ex_mem_valid;
            mem_wb_pc <= ex_mem_pc;
            mem_wb_rd <= ex_mem_rd;
            mem_wb_data <= ex_mem_mem_read ? dmem_rdata : ex_mem_result;
            mem_wb_reg_write <= ex_mem_reg_write;
            mem_wb_mem_write <= ex_mem_mem_write;
            mem_wb_mem_addr <= ex_mem_result;
            mem_wb_mem_data <= ex_mem_store_data;

            id_ex_pc <= if_id_pc;
            id_ex_pred_pc <= if_id_pred_pc;
            id_ex_raw_taken <= if_id_raw_taken;
            id_ex_pred_taken <= if_id_pred_taken;
            id_ex_btb_hit <= if_id_btb_hit;
            id_ex_rs <= id_rs;
            id_ex_rt <= id_rt;
            id_ex_shamt <= if_id_instruction[10:6];
            id_ex_rs_value <= id_rs_value;
            id_ex_rt_value <= id_rt_value;
            id_ex_immediate <= id_immediate;
            id_ex_rd <= id_rd;
            id_ex_alu_op <= id_alu_op;
            id_ex_use_immediate <= id_use_immediate;
            id_ex_reg_write <= id_reg_write;
            id_ex_mem_read <= id_mem_read;
            id_ex_mem_write <= id_mem_write;
            id_ex_branch_eq <= id_branch_eq;
            id_ex_branch_ne <= id_branch_ne;

            if (flush || (MODE == STALL_ON_BRANCH && branch_valid)) begin
                pc <= actual_next_pc;
                if_id_valid <= 1'b0;
                id_ex_valid <= 1'b0;
            end else if (load_stall) begin
                // Hold PC and IF/ID and put one bubble into EX.
                id_ex_valid <= 1'b0;
            end else if (MODE == STALL_ON_BRANCH && id_is_branch) begin
                // Issue the branch into EX but discard this cycle's fetch.
                if_id_valid <= 1'b0;
                id_ex_valid <= 1'b1;
            end else begin
                pc <= fetch_next_pc;
                if_id_valid <= 1'b1;
                if_id_pc <= pc;
                if_id_instruction <= imem_rdata;
                if_id_pred_pc <= fetch_next_pc;
                if_id_raw_taken <= fetch_raw_taken;
                if_id_pred_taken <= fetch_pred_taken;
                if_id_btb_hit <= fetch_btb_hit;
                id_ex_valid <= id_valid;
            end
        end
    end
endmodule

`default_nettype wire
